"""The real audio backend: USB mic → wake word → end of speech → Whisper,
and Piper (or espeak-ng) → speaker.

Each model runs on its own single worker thread, so the event loop (and the
WebSocket) stays responsive while Whisper transcribes or Piper synthesizes.
"""

from __future__ import annotations

import asyncio
import logging
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import TYPE_CHECKING

from . import stt, wakeword
from .audio import AudioError, Microphone, make_player
from .config import Config
from .pcm import level, rms
from .tts import Speaker, create_synth, piper_voice_path
from .vad import Endpointer, detector_factory
from .wakeword import WakeWordDetector, display_name

if TYPE_CHECKING:
    from .service import Session, VoiceService

log = logging.getLogger(__name__)

MIC_RETRY_SECONDS = 10
MIC_TIMEOUT_SECONDS = 2.0


class AudioBackend:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.wakeword_name = display_name(cfg.wakeword.model, cfg.wakeword.name)
        self._service: VoiceService | None = None
        self._detector: WakeWordDetector | None = None
        self._transcriber: stt.Transcriber | None = None
        self._speaker: Speaker | None = None
        self._mic_ok = False
        self._capture: asyncio.Queue[bytes] | None = None
        self._mic_task: asyncio.Task[None] | None = None
        v = cfg.vad
        try:
            self._new_vad = detector_factory(v.engine, v.aggressiveness, v.energy_threshold)
        except ImportError:
            log.warning("vad.engine is webrtc but webrtcvad isn't installed; using energy")
            self._new_vad = detector_factory("energy", v.aggressiveness, v.energy_threshold)
        self._wake_pool = ThreadPoolExecutor(1, thread_name_prefix="wakeword")
        self._stt_pool = ThreadPoolExecutor(1, thread_name_prefix="stt")
        self._tts_pool = ThreadPoolExecutor(1, thread_name_prefix="tts")

    @property
    def wakeword_available(self) -> bool:
        # A wake word that can't be followed by listening would only annoy.
        return self._detector is not None and self.stt_available

    @property
    def stt_available(self) -> bool:
        return self._transcriber is not None and self._mic_ok

    @property
    def tts_available(self) -> bool:
        return self._speaker is not None

    # Startup

    async def load(self) -> None:
        """Load the models (a few seconds on a Pi 5), each on its own thread."""
        loop = asyncio.get_running_loop()
        await asyncio.gather(
            loop.run_in_executor(self._wake_pool, self._load_wakeword),
            loop.run_in_executor(self._stt_pool, self._load_stt),
            loop.run_in_executor(self._tts_pool, self._load_tts),
        )

    def _load_wakeword(self) -> None:
        w = self.cfg.wakeword
        try:
            self._detector = WakeWordDetector(w.model, framework=w.inference_framework,
                                              data_dir=self.cfg.data_path)
        except ImportError:
            log.warning("wake word unavailable: openwakeword isn't installed; push-to-talk only")
        except Exception as e:
            log.warning("wake word unavailable (%s); push-to-talk only", e)

    def _load_stt(self) -> None:
        transcriber = stt.Transcriber(self.cfg.stt, self.cfg.data_path)
        try:
            transcriber.load()
        except ImportError:
            log.warning("listening unavailable: faster-whisper isn't installed")
            return
        except Exception as e:
            log.warning("listening unavailable: speech-to-text %s", e)
            return
        self._transcriber = transcriber

    def _load_tts(self) -> None:
        synth = create_synth(self.cfg.tts, self.cfg.data_path)
        if synth is not None:
            a = self.cfg.audio
            self._speaker = Speaker(synth, make_player(a.output, a.output_device))

    async def start(self, service: VoiceService) -> None:
        self._service = service
        self._mic_task = asyncio.get_running_loop().create_task(self._run_microphone())

    async def close(self) -> None:
        if self._mic_task is not None:
            self._mic_task.cancel()
            await asyncio.gather(self._mic_task, return_exceptions=True)
        if self._speaker is not None:
            self._speaker.abort()
        for pool in (self._wake_pool, self._stt_pool, self._tts_pool):
            pool.shutdown(wait=False, cancel_futures=True)

    # Microphone

    def _set_mic_ok(self, ok: bool) -> None:
        if ok != self._mic_ok:
            self._mic_ok = ok
            if self._service is not None:
                self._service.capabilities_changed()

    async def _run_microphone(self) -> None:
        """Keep a microphone open, reopening it if it's unplugged."""
        loop = asyncio.get_running_loop()
        warned = False
        while True:
            mic = Microphone(self.cfg.audio.input_device, self.cfg.audio.input_channel)
            try:
                mic.start(loop)
            except Exception as e:  # AudioError, or PortAudio failing outright
                if not warned:
                    log.warning("%s; trying again every %d s", e, MIC_RETRY_SECONDS)
                    warned = True
                await asyncio.sleep(MIC_RETRY_SECONDS)
                continue
            warned = False
            self._set_mic_ok(True)
            try:
                await self._pump(mic)
            except AudioError as e:
                log.warning("%s", e)
            except Exception:
                log.exception("audio loop failed; restarting it")
            finally:
                mic.close()
                self._set_mic_ok(False)
            await asyncio.sleep(2)

    async def _pump(self, mic: Microphone) -> None:
        """Route each frame: to the current session if there is one, else to
        the wake-word model when the gate allows."""
        assert self._service is not None
        loop = asyncio.get_running_loop()
        gate = self._service.gate
        threshold = self.cfg.wakeword.threshold
        while True:
            frame = await mic.read(MIC_TIMEOUT_SECONDS)
            if self._capture is not None:
                self._capture.put_nowait(frame)
                continue
            detector = self._detector
            if detector is None or not gate.allows():
                continue
            if gate.take_reset():
                await loop.run_in_executor(self._wake_pool, detector.reset)
            score = await loop.run_in_executor(self._wake_pool, detector.score, frame)
            if score >= threshold:
                log.info("wake word heard (score %.2f)", score)
                self._service.wake("wakeword")
            elif score >= threshold / 2:
                log.debug("wake word score %.2f (threshold %.2f)", score, threshold)

    # Listening

    def begin_capture(self) -> None:
        self._capture = asyncio.Queue()

    async def capture(self, session: Session) -> str:
        queue = self._capture
        if queue is None:
            queue = self._capture = asyncio.Queue()
        v = self.cfg.vad
        endpointer = Endpointer(self._new_vad(), silence=v.silence, max_length=v.max_length,
                                no_speech=v.no_speech)
        try:
            while endpointer.reason is None:
                try:
                    frame = await asyncio.wait_for(queue.get(), MIC_TIMEOUT_SECONDS)
                except TimeoutError:
                    raise AudioError("the microphone stopped sending audio") from None
                session.level(level(rms(frame)))
                endpointer.process(frame)
        finally:
            if self._capture is queue:
                self._capture = None
        log.info("utterance ended (%s) after %.1f s, %.1f s of speech",
                 endpointer.reason, endpointer.elapsed, endpointer.speech_length)
        if not endpointer.started or self._transcriber is None:
            return ""
        session.transcribing()
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._stt_pool, self._transcriber.transcribe,
                                          endpointer.audio())

    # Speaking

    async def speak(self, text: str) -> None:
        assert self._speaker is not None
        speaker = self._speaker
        stop = threading.Event()
        loop = asyncio.get_running_loop()
        future = loop.run_in_executor(self._tts_pool, speaker.speak, text, stop)
        # If we're cancelled the thread finishes on its own; don't leave its
        # result (or error) unretrieved.
        future.add_done_callback(lambda f: f.cancelled() or f.exception())
        try:
            await asyncio.shield(future)
        except asyncio.CancelledError:
            stop.set()
            speaker.abort()
            raise


def say(cfg: Config, text: str) -> int:
    """`--say`: speak once through the configured voice and output."""
    synth = create_synth(cfg.tts, cfg.data_path)
    if synth is None:
        print("No text-to-speech engine available (see the log above).", file=sys.stderr)
        return 1
    speaker = Speaker(synth, make_player(cfg.audio.output, cfg.audio.output_device))
    try:
        speaker.speak(text, threading.Event())
    except Exception as e:
        print(f"Couldn't play the speech: {e}", file=sys.stderr)
        return 1
    return 0


def download_models(cfg: Config) -> int:
    """`--download-models`: fetch everything the config needs into data_dir,
    so the service never downloads at runtime."""
    data_dir = cfg.data_path
    data_dir.mkdir(parents=True, exist_ok=True)
    failed = []

    if cfg.tts.engine in ("auto", "piper"):
        target = piper_voice_path(cfg.tts.voice, data_dir)
        if target.exists():
            log.info("piper voice already here: %s", target)
        elif cfg.tts.voice.endswith(".onnx"):
            log.warning("piper voice file %s not found; it's a path, so nothing to download",
                        target)
        else:
            log.info("downloading piper voice %s", cfg.tts.voice)
            result = subprocess.run([sys.executable, "-m", "piper.download_voices",
                                     "--data-dir", str(target.parent), cfg.tts.voice],
                                    check=False)
            if result.returncode != 0:
                failed.append("piper voice")

    log.info("fetching speech-to-text model %s", cfg.stt.model)
    try:
        stt.download_model(cfg.stt, data_dir)
    except Exception as e:
        log.error("speech-to-text model: %s", e)
        failed.append("speech-to-text model")

    log.info("fetching wake word model %s", cfg.wakeword.model)
    try:
        wakeword.download_models(cfg.wakeword.model, data_dir)
        WakeWordDetector(cfg.wakeword.model, framework=cfg.wakeword.inference_framework,
                         data_dir=data_dir)
    except Exception as e:
        log.error("wake word model: %s", e)
        failed.append("wake word model")

    if failed:
        print("Couldn't fetch: " + ", ".join(failed), file=sys.stderr)
        return 1
    print(f"Models are ready in {data_dir}")
    return 0

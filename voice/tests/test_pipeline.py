"""The real-hardware backend with its models and mic swapped for fakes: frame
routing, wake-word suppression, endpointing, Whisper hand-off, speech stop."""

from __future__ import annotations

import asyncio
import threading
from typing import Any

import pytest

from homeos_voice import pipeline
from homeos_voice.audio import AudioError
from homeos_voice.config import Config
from homeos_voice.pcm import FRAME_BYTES, SAMPLE_RATE, rms, silence, tone
from homeos_voice.pipeline import AudioBackend
from homeos_voice.service import VoiceService

WAKE = b"\x01\x00" * (FRAME_BYTES // 2)  # the fake detector's trigger; quiet to the VAD
QUIET = silence(0.08)


def speech_frames(seconds: float) -> list[bytes]:
    audio = tone(220, seconds, amplitude=0.4)
    return [audio[i : i + FRAME_BYTES] for i in range(0, len(audio), FRAME_BYTES)]


class FakeMic:
    def __init__(self) -> None:
        self.queue: asyncio.Queue[bytes | Exception] = asyncio.Queue()

    def feed(self, *frames: bytes) -> None:
        for f in frames:
            self.queue.put_nowait(f)

    async def read(self, timeout: float = 2.0) -> bytes:
        item = await self.queue.get()
        if isinstance(item, Exception):
            raise item
        await asyncio.sleep(0.001)  # let the service's tasks run between frames
        return item


class FakeDetector:
    def __init__(self) -> None:
        self.frames: list[bytes] = []
        self.resets = 0

    @property
    def scored(self) -> int:
        return len(self.frames)

    def score(self, frame: bytes) -> float:
        self.frames.append(frame)
        return 0.93 if frame == WAKE else 0.01

    def reset(self) -> None:
        self.resets += 1


class FakeTranscriber:
    def __init__(self) -> None:
        self.audio: list[bytes] = []

    def transcribe(self, pcm: bytes) -> str:
        self.audio.append(pcm)
        return "what's for dinner"


class FakeSpeaker:
    def __init__(self, seconds: float = 0.3) -> None:
        self.seconds = seconds
        self.said: list[str] = []
        self.stopped = threading.Event()
        self.aborted = False

    def speak(self, text: str, stop: threading.Event) -> None:
        self.said.append(text)
        if stop.wait(self.seconds):
            self.stopped.set()

    def abort(self) -> None:
        self.aborted = True


class Rig:
    """An AudioBackend wired to fakes and a VoiceService that records broadcasts."""

    def __init__(self, **service_options: Any) -> None:
        cfg = Config()
        cfg.vad.engine = "energy"
        self.backend = AudioBackend(cfg)
        self.detector = FakeDetector()
        self.transcriber = FakeTranscriber()
        self.speaker = FakeSpeaker()
        self.backend._detector = self.detector
        self.backend._transcriber = self.transcriber
        self.backend._speaker = self.speaker
        self.backend._mic_ok = True
        service_options.setdefault("refractory", 0.0)
        service_options.setdefault("resume_delay", 0.0)
        self.service = VoiceService(self.backend, **service_options)
        self.events: list[dict[str, Any]] = []
        self.service.broadcast = self.events.append  # type: ignore[method-assign]
        self.backend._service = self.service
        self.mic = FakeMic()
        self.pump: asyncio.Task[None] | None = None

    def start(self) -> None:
        self.pump = asyncio.get_running_loop().create_task(self.backend._pump(self.mic))

    async def wait_for(self, want: dict[str, Any], timeout: float = 3.0) -> None:
        async with asyncio.timeout(timeout):
            while not any(all(e.get(k) == v for k, v in want.items()) for e in self.events):
                await asyncio.sleep(0.01)

    def kinds(self) -> list[str]:
        return [e["type"] for e in self.events if e["type"] != "level"]

    async def stop(self) -> None:
        if self.pump is not None:
            self.pump.cancel()
            await asyncio.gather(self.pump, return_exceptions=True)
        await self.service.close()
        await self.backend.close()


async def test_wake_word_then_utterance_then_transcript():
    rig = Rig()
    rig.start()
    rig.mic.feed(QUIET, QUIET, WAKE, *speech_frames(1.0), *[QUIET] * 15)
    await rig.wait_for({"type": "transcript"})
    assert rig.kinds() == ["wake", "state", "state", "transcript", "state"]
    assert rig.events[0] == {"type": "wake", "source": "wakeword"}
    assert {"type": "transcript", "text": "what's for dinner", "final": True} in rig.events
    levels = [e["rms"] for e in rig.events if e["type"] == "level"]
    assert levels and max(levels) > 0.8  # the 0.4-amplitude tone is loud
    # Whisper got the speech plus a little before and the 0.7 s tail.
    (audio,) = rig.transcriber.audio
    seconds = len(audio) / 2 / SAMPLE_RATE
    assert 1.0 + 0.7 <= seconds <= 0.5 + 1.0 + 0.7 + 0.08
    # Frames during the session went to the endpointer, not the wake model.
    assert rig.detector.frames[:3] == [QUIET, QUIET, WAKE]
    assert all(rms(f) < 0.01 for f in rig.detector.frames)
    await rig.stop()


async def test_audio_right_after_the_wake_word_is_kept():
    rig = Rig()
    rig.start()
    # The command starts in the very next frame after the wake word.
    rig.mic.feed(WAKE, *speech_frames(0.4), *[QUIET] * 12)
    await rig.wait_for({"type": "transcript"})
    (audio,) = rig.transcriber.audio
    assert len(audio) / 2 / SAMPLE_RATE >= 0.4 + 0.7
    await rig.stop()


async def test_nothing_said_gives_an_empty_transcript_without_whisper(monkeypatch):
    rig = Rig()
    rig.backend.cfg.vad.no_speech = 0.5
    rig.start()
    rig.mic.feed(WAKE, *[QUIET] * 10)
    await rig.wait_for({"type": "transcript"})
    assert {"type": "transcript", "text": "", "final": True} in rig.events
    assert "transcribing" not in [e.get("state") for e in rig.events]
    assert rig.transcriber.audio == []
    await rig.stop()


async def test_wake_word_is_not_even_scored_while_speaking():
    rig = Rig(resume_delay=0.2)
    rig.speaker.seconds = 0.4
    rig.start()
    rig.mic.feed(QUIET)
    await asyncio.sleep(0.05)
    scored = rig.detector.scored
    resets = rig.detector.resets
    rig.service.speak("Tacos tonight", "r1")
    await rig.wait_for({"type": "state", "state": "speaking"})
    rig.mic.feed(WAKE, WAKE, WAKE)  # it hears its own "wake word"
    await rig.wait_for({"type": "spoken", "id": "r1"})
    assert "wake" not in rig.kinds()
    assert rig.detector.scored == scored
    # After the resume delay it listens again, with fresh buffers.
    await asyncio.sleep(0.25)
    rig.mic.feed(WAKE)
    await rig.wait_for({"type": "wake"})
    assert rig.detector.resets == resets + 1
    assert rig.detector.scored == scored + 1
    await rig.stop()


async def test_push_to_talk_works_with_the_wake_word_off():
    rig = Rig()
    rig.service.set_wakeword_enabled(False)
    rig.start()
    rig.mic.feed(WAKE, WAKE)
    await asyncio.sleep(0.1)
    assert "wake" not in rig.kinds()
    assert rig.events[-1]["type"] == "hello" and rig.events[-1]["wakeword"] is False
    rig.service.wake("button")
    rig.mic.feed(*speech_frames(0.5), *[QUIET] * 12)
    await rig.wait_for({"type": "transcript"})
    assert {"type": "wake", "source": "button"} in rig.events
    await rig.stop()


async def test_mic_failure_mid_session_ends_it_with_an_error(monkeypatch):
    monkeypatch.setattr(pipeline, "MIC_TIMEOUT_SECONDS", 0.2)
    rig = Rig()
    rig.start()
    rig.mic.feed(WAKE, *speech_frames(0.3))
    await rig.wait_for({"type": "state", "state": "listening"})
    await rig.wait_for({"type": "transcript"})  # the mic went quiet
    errors = [e for e in rig.events if e["type"] == "error"]
    assert errors and "microphone stopped" in errors[0]["message"]
    assert {"type": "transcript", "text": "", "final": True} in rig.events
    assert rig.service.state == "idle"
    await rig.stop()


async def test_stop_speaking_stops_the_audio_thread():
    rig = Rig()
    rig.speaker.seconds = 5
    rig.service.speak("a very long answer", "long")
    await rig.wait_for({"type": "state", "state": "speaking"})
    await asyncio.sleep(0.05)
    rig.service.stop_speaking()
    assert rig.events[-2:] == [{"type": "spoken", "id": "long"},
                               {"type": "state", "state": "idle"}]
    assert await asyncio.to_thread(rig.speaker.stopped.wait, 1.0)
    assert rig.speaker.aborted
    await rig.stop()


async def test_microphone_comes_and_goes(monkeypatch):
    monkeypatch.setattr(pipeline, "MIC_RETRY_SECONDS", 0.05)
    attempts: list[str] = []
    mics: list[FakeMic] = []

    class FlakyMicrophone(FakeMic):
        def __init__(self, device: Any, channel: int) -> None:
            super().__init__()

        def start(self, loop: Any) -> None:
            attempts.append("start")
            if len(attempts) == 1:
                raise AudioError("no microphone found; plug in a USB mic (the panel has none)")
            mics.append(self)

        def close(self) -> None:
            attempts.append("close")

    monkeypatch.setattr(pipeline, "Microphone", FlakyMicrophone)
    rig = Rig()
    rig.backend._mic_ok = False
    rig.service.gate.available = False
    assert rig.service.hello()["stt"] is False
    await rig.backend.start(rig.service)
    await rig.wait_for({"type": "hello", "stt": True, "wakeword": True})
    mics[0].feed(AudioError("the microphone stopped sending audio"))  # unplugged
    await rig.wait_for({"type": "hello", "stt": False})
    assert attempts[:3] == ["start", "start", "close"]
    await rig.stop()


def test_wake_word_needs_speech_to_text():
    rig = Rig()
    assert rig.backend.wakeword_available
    rig.backend._transcriber = None
    assert not rig.backend.wakeword_available and not rig.backend.stt_available
    rig.backend._mic_ok = False
    rig.backend._transcriber = FakeTranscriber()
    assert not rig.backend.wakeword_available
    asyncio.run(rig.backend.close())


def test_backend_reports_missing_models(tmp_path, monkeypatch, caplog):
    """With nothing installed the service still starts: no wake word, no
    listening, and spoken replies only if espeak-ng is around."""
    import sys

    for name in ("openwakeword", "openwakeword.model", "faster_whisper", "piper"):
        monkeypatch.setitem(sys.modules, name, None)
    monkeypatch.setenv("PATH", str(tmp_path))
    cfg = Config()
    cfg.data_dir = str(tmp_path)
    backend = AudioBackend(cfg)
    asyncio.run(backend.load())
    backend._mic_ok = True
    assert not backend.wakeword_available
    assert not backend.stt_available
    assert not backend.tts_available
    messages = " ".join(r.getMessage() for r in caplog.records)
    assert "openwakeword isn't installed" in messages
    assert "faster-whisper isn't installed" in messages
    assert "spoken replies unavailable" in messages
    asyncio.run(backend.close())


@pytest.mark.parametrize("exists", [False, True])
def test_piper_voice_path(tmp_path, exists):
    from homeos_voice.tts import piper_voice_path

    assert piper_voice_path("en_US-amy-medium", tmp_path) == (
        tmp_path / "piper" / "en_US-amy-medium.onnx")
    custom = tmp_path / "voices" / "mine.onnx"
    if exists:
        custom.parent.mkdir()
        custom.write_bytes(b"")
    assert piper_voice_path(str(custom), tmp_path) == custom

"""Microphone capture (sounddevice/PortAudio) and playback (aplay or
sounddevice). Imports of sounddevice and numpy happen only when used."""

from __future__ import annotations

import asyncio
import logging
import shutil
import subprocess
import threading
from collections.abc import Callable, Iterable
from typing import Any, Protocol

from .pcm import FRAME_SAMPLES, SAMPLE_RATE, pick_channel

log = logging.getLogger(__name__)

FRAME_SECONDS = FRAME_SAMPLES / SAMPLE_RATE


class AudioError(Exception):
    """No usable microphone or speaker, or the audio stack is missing."""


def load_sounddevice() -> Any:
    try:
        import sounddevice as sd
    except ImportError:
        raise AudioError(
            "sounddevice isn't installed (pip install 'homeos-voice[audio]')") from None
    except OSError as e:  # sounddevice raises this when libportaudio is missing
        raise AudioError(f"PortAudio isn't available ({e}); apt install libportaudio2") from None
    return sd


def describe_devices() -> str:
    sd = load_sounddevice()
    devices = sd.query_devices()
    if not len(devices):
        return "No audio devices found. Is the USB mic plugged in? (`arecord -l` lists them too.)"
    return str(devices)


def _as_device(value: str | int) -> str | int | None:
    if value == "":
        return None
    if isinstance(value, str) and value.strip().isdigit():
        return int(value)
    return value


def input_candidates(devices: list[dict[str, Any]], default_input: int,
                     wanted: str | int) -> list[int]:
    """Device indexes to try, best first. With no preference a USB mic wins:
    the system default is often the HDMI panel, which has no microphone."""
    inputs = [i for i, d in enumerate(devices) if d["max_input_channels"] > 0]
    want = _as_device(wanted)
    if isinstance(want, int):
        if want not in inputs:
            raise AudioError(f"audio device {want} has no microphone input (see --list-devices)")
        return [want]
    if isinstance(want, str):
        matches = [i for i in inputs if want.lower() in devices[i]["name"].lower()]
        if not matches:
            raise AudioError(f"no microphone matching '{want}' (see --list-devices)")
        return matches
    if not inputs:
        raise AudioError("no microphone found; plug in a USB mic (the panel has none)")
    usb = [i for i in inputs if "usb" in devices[i]["name"].lower()]
    default = [default_input] if default_input in inputs else []
    return list(dict.fromkeys(usb + default + inputs))


def make_resampler(src_rate: int) -> Callable[[bytes], bytes]:
    """Converts one block from the mic's own rate to 16 kHz. A box filter
    first takes the edge off aliasing when downsampling (48 kHz → 16 kHz)."""
    import numpy as np

    ratio = src_rate / SAMPLE_RATE
    width = max(1, round(ratio))
    kernel = np.ones(width, dtype=np.float32) / width

    def resample(pcm: bytes) -> bytes:
        x = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
        if width > 1:
            x = np.convolve(x, kernel, mode="same")
        n_out = round(len(x) / ratio)
        y = np.interp(np.arange(n_out) * ratio, np.arange(len(x)), x)
        return np.clip(np.rint(y), -32768, 32767).astype("<i2").tobytes()

    return resample


class Microphone:
    """Streams 80 ms frames of 16 kHz mono int16 into an asyncio queue."""

    def __init__(self, device: str | int = "", channel: int = 0, max_frames: int = 50) -> None:
        self.device = device
        self.channel = channel
        self.name = ""
        self._queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=max_frames)
        self._stream: Any = None
        self._dropped = 0

    def start(self, loop: asyncio.AbstractEventLoop) -> None:
        sd = load_sounddevice()
        devices = list(sd.query_devices())
        default_input = sd.default.device[0]
        errors = []
        for index in input_candidates(devices, default_input, self.device):
            try:
                self._open(sd, index, devices[index], loop)
                return
            except Exception as e:  # PortAudio errors vary by host API
                errors.append(f"{devices[index]['name']}: {e}")
        raise AudioError("couldn't open a microphone: " + "; ".join(errors))

    def _open(self, sd: Any, index: int, info: dict[str, Any],
              loop: asyncio.AbstractEventLoop) -> None:
        native = int(info["default_samplerate"])
        most = int(info["max_input_channels"])
        # Mono at 16 kHz is ideal; raw hardware devices may only offer their
        # own rate or channel count, which we convert ourselves.
        for rate, channels in dict.fromkeys(
            [(SAMPLE_RATE, 1), (native, 1), (SAMPLE_RATE, most), (native, most)]
        ):
            try:
                sd.check_input_settings(device=index, samplerate=rate, channels=channels,
                                        dtype="int16")
            except Exception:
                continue
            break
        else:
            raise AudioError("no supported sample rate / channel layout")

        resample = make_resampler(rate) if rate != SAMPLE_RATE else None
        channel = min(self.channel, channels - 1)

        def callback(indata: Any, frames: int, time_info: Any, status: Any) -> None:
            if status:
                log.debug("microphone: %s", status)
            data = bytes(indata)
            if channels > 1:
                data = pick_channel(data, channels, channel)
            if resample is not None:
                data = resample(data)
            loop.call_soon_threadsafe(self._push, data)

        stream = sd.RawInputStream(
            device=index,
            samplerate=rate,
            channels=channels,
            dtype="int16",
            blocksize=round(rate * FRAME_SECONDS),
            callback=callback,
        )
        stream.start()
        self._stream = stream
        self.name = info["name"]
        log.info("microphone: %s (%d Hz, %d ch)", self.name, rate, channels)

    def _push(self, frame: bytes) -> None:
        if self._queue.full():
            # We fell behind (a slow model on a busy CPU): drop the oldest audio.
            self._queue.get_nowait()
            self._dropped += 1
            if self._dropped in (1, 100) or self._dropped % 1000 == 0:
                log.warning("microphone: dropped %d frames (CPU too busy?)", self._dropped)
        self._queue.put_nowait(frame)

    async def read(self, timeout: float = 2.0) -> bytes:
        try:
            return await asyncio.wait_for(self._queue.get(), timeout)
        except TimeoutError:
            raise AudioError("the microphone stopped sending audio") from None

    def close(self) -> None:
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception as e:
                log.debug("closing microphone: %s", e)


class Player(Protocol):
    def play(self, rate: int, chunks: Iterable[bytes], stop: threading.Event) -> None:
        """Play 16-bit mono chunks; returns when done or soon after `stop` is set."""
        ...

    def abort(self) -> None: ...


class AplayPlayer:
    """Pipes audio into ALSA's aplay. `device` is an ALSA name from `aplay -L`,
    e.g. "default:CARD=vc4hdmi0" for the Pi 5's first HDMI port."""

    def __init__(self, device: str | int = "") -> None:
        self.device = str(device)
        self._proc: subprocess.Popen[bytes] | None = None
        self._lock = threading.Lock()

    def play(self, rate: int, chunks: Iterable[bytes], stop: threading.Event) -> None:
        cmd = ["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-c", "1", "-r", str(rate)]
        if self.device:
            cmd += ["-D", self.device]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        assert proc.stdin is not None and proc.stderr is not None
        with self._lock:
            self._proc = proc
        try:
            for chunk in chunks:
                if stop.is_set():
                    break
                proc.stdin.write(chunk)
        except BrokenPipeError:
            pass  # aplay was stopped, or failed (reported below)
        finally:
            try:
                proc.stdin.close()  # aplay plays what's buffered, then exits
            except OSError:
                pass
            if stop.is_set() and proc.poll() is None:
                proc.kill()
            proc.wait()
            with self._lock:
                self._proc = None
        if proc.returncode != 0 and not stop.is_set():
            lines = proc.stderr.read().decode(errors="replace").strip().splitlines()
            # ALSA prints a page of config noise before the actual reason.
            log.debug("aplay: %s", "\n".join(lines))
            raise AudioError(f"aplay failed: {lines[-1] if lines else proc.returncode}")

    def abort(self) -> None:
        with self._lock:
            if self._proc is not None and self._proc.poll() is None:
                self._proc.kill()


class SoundDevicePlayer:
    """Plays through PortAudio. `device` is a sounddevice index or name."""

    def __init__(self, device: str | int = "") -> None:
        self.device = _as_device(device)

    def play(self, rate: int, chunks: Iterable[bytes], stop: threading.Event) -> None:
        sd = load_sounddevice()
        piece = rate // 10 * 2  # 100 ms, so a stop takes effect quickly
        with sd.RawOutputStream(samplerate=rate, channels=1, dtype="int16",
                                device=self.device) as out:
            for chunk in chunks:
                for offset in range(0, len(chunk), piece):
                    if stop.is_set():
                        out.abort()
                        return
                    out.write(chunk[offset : offset + piece])

    def abort(self) -> None:
        pass  # play() polls the stop event between 100 ms writes


def make_player(output: str, device: str | int) -> Player:
    if output == "aplay" or (output == "auto" and shutil.which("aplay")):
        return AplayPlayer(device)
    return SoundDevicePlayer(device)

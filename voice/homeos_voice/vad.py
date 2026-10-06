"""End of speech: decides when the person has finished talking.

An utterance ends after `silence` seconds of quiet once speech has started,
after `max_length` seconds of speech, or after `no_speech` seconds without any
speech at all. Speech is judged every 20 ms by webrtcvad, or by an adaptive
energy threshold when webrtcvad isn't installed.
"""

from __future__ import annotations

import logging
from collections import deque
from collections.abc import Callable
from typing import Protocol

from .pcm import SAMPLE_RATE, rms

log = logging.getLogger(__name__)

SUB_MS = 20  # webrtcvad takes 10, 20 or 30 ms
SUB_BYTES = SAMPLE_RATE * SUB_MS // 1000 * 2


class SpeechDetector(Protocol):
    name: str

    def is_speech(self, sub: bytes) -> bool:
        """One 20 ms, 16 kHz mono int16 chunk: is someone talking?"""
        ...


class WebRtcDetector:
    name = "webrtc"

    def __init__(self, aggressiveness: int = 2) -> None:
        import webrtcvad  # optional: the `audio` extra

        self._vad = webrtcvad.Vad(aggressiveness)

    def is_speech(self, sub: bytes) -> bool:
        return self._vad.is_speech(sub, SAMPLE_RATE)


class EnergyDetector:
    """Loudness against a running noise floor. Cruder than webrtcvad (any
    steady sound above the floor counts), but needs nothing installed."""

    name = "energy"

    def __init__(self, threshold: float = 0.015, ratio: float = 3.0) -> None:
        self.threshold = threshold
        self.ratio = ratio
        self.noise = threshold / ratio

    def is_speech(self, sub: bytes) -> bool:
        r = rms(sub)
        speech = r > max(self.threshold, self.noise * self.ratio)
        # The floor follows quiet chunks quickly and loud ones slowly, so a
        # steady hum (a fan, the dishwasher) stops counting as speech.
        self.noise += (0.002 if speech else 0.05) * (r - self.noise)
        return speech


def detector_factory(engine: str = "auto", aggressiveness: int = 2,
                     energy_threshold: float = 0.015) -> Callable[[], SpeechDetector]:
    """A function making a fresh detector per utterance. Checks once whether
    webrtcvad is importable and falls back to energy for `auto`."""
    if engine in ("auto", "webrtc"):
        try:
            WebRtcDetector(aggressiveness)
        except ImportError:
            if engine == "webrtc":
                raise
            log.warning("webrtcvad isn't installed; using the energy-based speech detector")
        else:
            return lambda: WebRtcDetector(aggressiveness)
    return lambda: EnergyDetector(energy_threshold)


class Endpointer:
    """Feed it 16 kHz mono frames; `process` returns why the utterance ended
    ("silence", "max_length" or "no_speech") once it has, else None."""

    def __init__(
        self,
        detector: SpeechDetector,
        *,
        silence: float = 0.7,
        max_length: float = 8.0,
        no_speech: float = 4.0,
        min_speech: float = 0.12,
        start_window: float = 0.3,
        preroll: float = 0.5,
    ) -> None:
        def subs(seconds: float) -> int:
            return max(1, round(seconds * 1000 / SUB_MS))

        self._detector = detector
        self._silence = subs(silence)
        self._max = subs(max_length)
        self._no_speech = subs(no_speech)
        # Speech has started once `min_speech` of the last `start_window` was
        # voiced, so a cough or a click doesn't count.
        self._min_speech = subs(min_speech)
        self._recent: deque[bool] = deque(maxlen=subs(start_window))
        # Audio from just before the start is kept so the first word isn't clipped.
        self._preroll: deque[bytes] = deque(maxlen=subs(preroll))
        self._audio = bytearray()
        self._pending = b""
        self._elapsed = 0
        self._spoken = 0
        self._quiet = 0
        self.started = False
        self.reason: str | None = None

    @property
    def elapsed(self) -> float:
        return self._elapsed * SUB_MS / 1000

    @property
    def speech_length(self) -> float:
        return self._spoken * SUB_MS / 1000

    def audio(self) -> bytes:
        """The utterance: a little audio before speech started, then everything after."""
        return bytes(self._audio)

    def process(self, frame: bytes) -> str | None:
        if self.reason is not None:
            return self.reason
        data = self._pending + frame
        usable = len(data) - len(data) % SUB_BYTES
        self._pending = data[usable:]
        for offset in range(0, usable, SUB_BYTES):
            if self._step(data[offset : offset + SUB_BYTES]):
                break
        return self.reason

    def _step(self, sub: bytes) -> bool:
        voiced = self._detector.is_speech(sub)
        self._elapsed += 1
        if not self.started:
            self._preroll.append(sub)
            self._recent.append(voiced)
            if sum(self._recent) >= self._min_speech:
                self.started = True
                self._audio.extend(b"".join(self._preroll))
                self._preroll.clear()
            elif self._elapsed >= self._no_speech:
                self.reason = "no_speech"
            return self.reason is not None

        self._audio.extend(sub)
        self._spoken += 1
        self._quiet = 0 if voiced else self._quiet + 1
        if self._quiet >= self._silence:
            self.reason = "silence"
        elif self._spoken >= self._max:
            self.reason = "max_length"
        return self.reason is not None

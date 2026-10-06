"""End-of-speech detection on synthetic audio."""

from __future__ import annotations

import sys

import pytest
from helpers import vowel

from homeos_voice import vad
from homeos_voice.pcm import FRAME_BYTES, SAMPLE_RATE, rms, silence, tone
from homeos_voice.vad import Endpointer, EnergyDetector

FRAME_S = 0.08


class LoudIsSpeech:
    """Deterministic stand-in for webrtcvad: loud means speech."""

    name = "fake"

    def is_speech(self, sub: bytes) -> bool:
        return rms(sub) > 0.05


def frames(audio: bytes) -> list[bytes]:
    return [audio[i : i + FRAME_BYTES] for i in range(0, len(audio), FRAME_BYTES)]


def feed(endpointer: Endpointer, audio: bytes) -> tuple[str | None, float]:
    """Feed frame by frame; (reason, seconds fed when it ended)."""
    for n, frame in enumerate(frames(audio), start=1):
        if endpointer.process(frame):
            return endpointer.reason, n * FRAME_S
    return None, len(audio) / 2 / SAMPLE_RATE


def speech(seconds: float) -> bytes:
    return tone(220, seconds, amplitude=0.4)


def test_nothing_said_ends_after_no_speech_timeout():
    ep = Endpointer(LoudIsSpeech())
    reason, at = feed(ep, silence(10))
    assert reason == "no_speech"
    assert at == pytest.approx(4.0, abs=FRAME_S)
    assert not ep.started
    assert ep.audio() == b""


def test_utterance_ends_after_700ms_of_silence():
    ep = Endpointer(LoudIsSpeech())
    reason, at = feed(ep, silence(0.5) + speech(1.5) + silence(3))
    assert reason == "silence"
    assert at == pytest.approx(0.5 + 1.5 + 0.7, abs=FRAME_S)
    # The kept audio starts a little before the speech and includes the tail.
    seconds = len(ep.audio()) / 2 / SAMPLE_RATE
    assert 1.5 + 0.7 <= seconds <= 0.5 + 1.5 + 0.7 + FRAME_S


def test_short_pauses_dont_end_the_utterance():
    ep = Endpointer(LoudIsSpeech())
    audio = speech(1) + silence(0.4) + speech(1) + silence(0.5) + speech(0.5) + silence(2)
    reason, at = feed(ep, audio)
    assert reason == "silence"
    assert at == pytest.approx(3.4 + 0.7, abs=FRAME_S)


def test_long_speech_is_cut_at_max_length():
    ep = Endpointer(LoudIsSpeech())
    reason, at = feed(ep, speech(12))
    assert reason == "max_length"
    assert at == pytest.approx(8.0 + 0.12, abs=FRAME_S)
    assert ep.speech_length == pytest.approx(8.0, abs=0.03)


def test_speech_starting_late_is_still_heard():
    ep = Endpointer(LoudIsSpeech())
    reason, _ = feed(ep, silence(3.5) + speech(1) + silence(1))
    assert reason == "silence"
    assert ep.started


def test_a_click_is_not_speech():
    ep = Endpointer(LoudIsSpeech())
    reason, _ = feed(ep, silence(1) + speech(0.06) + silence(5))
    assert reason == "no_speech"


def test_settings_change_the_timing():
    ep = Endpointer(LoudIsSpeech(), silence=0.3, max_length=2.0, no_speech=1.0)
    assert feed(ep, speech(1) + silence(1)) == ("silence", pytest.approx(1.3, abs=FRAME_S))
    ep = Endpointer(LoudIsSpeech(), silence=0.3, max_length=2.0, no_speech=1.0)
    assert feed(ep, silence(2))[0] == "no_speech"


def test_odd_sized_frames_are_handled():
    ep = Endpointer(LoudIsSpeech())
    audio = speech(1) + silence(1)
    for i in range(0, len(audio), 1001):  # not a multiple of 20 ms, or even of 2 bytes
        if ep.process(audio[i : i + 1001]):
            break
    assert ep.reason == "silence"


def test_endpointer_stays_finished():
    ep = Endpointer(LoudIsSpeech(), no_speech=0.2)
    feed(ep, silence(1))
    assert ep.process(speech(1)) == "no_speech"


def test_energy_detector_separates_quiet_from_loud():
    det = EnergyDetector(threshold=0.015)
    sub = vad.SUB_BYTES
    assert not det.is_speech(silence(0.02))
    assert det.is_speech(tone(300, 0.02, amplitude=0.3)[:sub])
    assert not det.is_speech(tone(300, 0.02, amplitude=0.005)[:sub])


def test_energy_detector_adapts_to_a_steady_hum():
    det = EnergyDetector(threshold=0.015)
    hum = tone(120, 0.02, amplitude=0.03)  # rms ≈ 0.02, above the bare threshold
    decisions = [det.is_speech(hum) for _ in range(250)]  # 5 s
    assert decisions[0] is True
    assert decisions[-1] is False
    # Real speech still stands out above the hum.
    assert det.is_speech(tone(300, 0.02, amplitude=0.4))


def test_energy_endpointing_end_to_end():
    ep = Endpointer(EnergyDetector())
    reason, at = feed(ep, silence(0.3) + speech(1.2) + silence(2))
    assert reason == "silence"
    assert at == pytest.approx(0.3 + 1.2 + 0.7, abs=2 * FRAME_S)


def test_factory_falls_back_to_energy_without_webrtcvad(monkeypatch):
    monkeypatch.setitem(sys.modules, "webrtcvad", None)  # import now fails
    assert vad.detector_factory("auto")().name == "energy"
    assert vad.detector_factory("energy")().name == "energy"
    with pytest.raises(ImportError):
        vad.detector_factory("webrtc")


def test_webrtcvad_endpointing_on_a_synthetic_vowel():
    pytest.importorskip("webrtcvad")
    make = vad.detector_factory("auto", aggressiveness=2)
    assert make().name == "webrtc"
    det = make()
    sub = vad.SUB_BYTES
    assert not det.is_speech(silence(0.02))
    voiced = vowel(0.5)
    assert sum(det.is_speech(voiced[i : i + sub]) for i in range(0, len(voiced), sub)) >= 20

    ep = Endpointer(make())
    reason, at = feed(ep, silence(0.4) + vowel(1.0) + silence(2))
    assert reason == "silence"
    assert at == pytest.approx(0.4 + 1.0 + 0.7, abs=2 * FRAME_S)
    ep = Endpointer(make())
    assert feed(ep, silence(5))[0] == "no_speech"

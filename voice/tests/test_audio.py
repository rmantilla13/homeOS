"""PCM helpers, device choice, playback and text-to-speech plumbing."""

from __future__ import annotations

import asyncio
import io
import os
import shutil
import stat
import sys
import threading
import time
import wave
from types import SimpleNamespace

import pytest

from homeos_voice import audio, pcm
from homeos_voice.audio import (
    AplayPlayer,
    AudioError,
    Microphone,
    input_candidates,
    make_player,
)
from homeos_voice.config import TtsConfig
from homeos_voice.stt import clean_transcript
from homeos_voice.tts import EspeakSynth, Speaker, clean_for_speech, create_synth


def wav_bytes(frames: bytes, rate: int = 22050, channels: int = 1) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames)
    return buf.getvalue()


def test_rms_and_level():
    assert pcm.rms(pcm.silence(0.1)) == 0.0
    assert pcm.rms(pcm.tone(440, 0.1, amplitude=0.5)) == pytest.approx(0.5 / 2**0.5, rel=0.02)
    assert pcm.level(0.0) == 0.0
    assert pcm.level(1.0) == 1.0
    assert pcm.level(0.001) == pytest.approx(0.0, abs=1e-9)  # -60 dBFS
    assert pcm.level(0.0316) == pytest.approx(0.5, abs=0.01)  # -30 dBFS
    assert pcm.rms(b"\x01") == 0.0  # a lone odd byte is ignored


def test_pick_channel():
    stereo = pcm.to_bytes(__import__("array").array("h", [1, -1, 2, -2, 3, -3]))
    assert pcm.samples(pcm.pick_channel(stereo, 2, 0)).tolist() == [1, 2, 3]
    assert pcm.samples(pcm.pick_channel(stereo, 2, 1)).tolist() == [-1, -2, -3]
    assert pcm.pick_channel(stereo, 1, 0) == stereo


def test_parse_wav():
    audio = pcm.tone(300, 0.05)
    assert pcm.parse_wav(wav_bytes(audio, 22050)) == (22050, 1, audio)


def test_parse_wav_with_streaming_placeholder_sizes():
    audio = pcm.tone(300, 0.05)
    data = bytearray(wav_bytes(audio, 22050))
    data[4:8] = b"\xff\xff\xff\x7f"  # RIFF size
    data[40:44] = b"\xff\xff\xff\x7f"  # data size, as espeak-ng writes to a pipe
    assert pcm.parse_wav(bytes(data)) == (22050, 1, audio)
    data[40:44] = b"\x00\x00\x00\x00"
    assert pcm.parse_wav(bytes(data))[2] == audio


def test_parse_wav_rejects_other_things():
    with pytest.raises(ValueError):
        pcm.parse_wav(b"OggS" + bytes(40))
    with pytest.raises(ValueError):
        pcm.parse_wav(wav_bytes(b"")[:36])


DEVICES = [
    {"name": "vc4-hdmi-0: MAI PCM i2s-hifi-0 (hw:0,0)", "max_input_channels": 0},
    {"name": "Built-in Line In", "max_input_channels": 2},
    {"name": "USB PnP Sound Device: Audio (hw:2,0)", "max_input_channels": 1},
    {"name": "default", "max_input_channels": 32},
]


def test_input_candidates_prefer_a_usb_mic():
    assert input_candidates(DEVICES, 3, "") == [2, 3, 1]
    assert input_candidates(DEVICES, -1, "") == [2, 1, 3]
    assert input_candidates(DEVICES, 3, "line") == [1]
    assert input_candidates(DEVICES, 3, 3) == [3]
    assert input_candidates(DEVICES, 3, "2") == [2]
    with pytest.raises(AudioError, match="no microphone input"):
        input_candidates(DEVICES, 3, 0)
    with pytest.raises(AudioError, match="no microphone matching"):
        input_candidates(DEVICES, 3, "respeaker")
    with pytest.raises(AudioError, match="plug in a USB mic"):
        input_candidates(DEVICES[:1], -1, "")


class FakePortAudio:
    """sounddevice as far as Microphone uses it. Like PortAudio, the device
    list is only read when it's initialised."""

    def __init__(self) -> None:
        self.attached: list[dict] = []  # what's actually plugged in
        self.devices: list[dict] = []  # what PortAudio saw at initialisation
        self.default = SimpleNamespace(device=[-1, -1])
        self._initialized = 1
        self.opened: list[int] = []

    def plug_in_usb_mic(self) -> None:
        self.attached.append({"name": "USB PnP Sound Device: Audio (hw:2,0)",
                              "max_input_channels": 1, "default_samplerate": 48000.0})

    def query_devices(self) -> list[dict]:
        return list(self.devices)

    def _terminate(self) -> None:
        self._initialized -= 1

    def _initialize(self) -> None:
        self._initialized += 1
        self.devices = list(self.attached)

    def check_input_settings(self, **kwargs) -> None:
        pass

    def RawInputStream(self, *, device: int, **kwargs) -> SimpleNamespace:
        self.opened.append(device)
        return SimpleNamespace(start=lambda: None, stop=lambda: None, close=lambda: None)


def test_a_mic_plugged_in_after_startup_is_found(monkeypatch):
    sd = FakePortAudio()
    monkeypatch.setattr(audio, "load_sounddevice", lambda: sd)
    loop = asyncio.new_event_loop()
    try:
        sd.plug_in_usb_mic()  # after PortAudio was initialised
        with pytest.raises(AudioError, match="no microphone found"):
            Microphone().start(loop)
        # While our own output stream is open a re-scan would close it: skipped.
        with audio.portaudio_in_use:
            with pytest.raises(AudioError, match="no microphone found"):
                Microphone().start(loop, rescan=True)
        mic = Microphone()
        mic.start(loop, rescan=True)
        assert mic.name.startswith("USB PnP") and sd.opened == [0]
        assert sd._initialized == 1
        mic.close()
    finally:
        loop.close()


def test_clean_for_speech():
    assert clean_for_speech("Dinner is **tacos** 🌮 at 6.") == "Dinner is tacos at 6."
    assert clean_for_speech("Shopping list:\n- eggs\n- milk\n1. bread") == (
        "Shopping list: eggs. milk. bread.")
    assert clean_for_speech("See https://example.com/x for more") == "See a link for more"
    assert clean_for_speech("## Today\n`code` and *soft* words") == "Today. code and soft words."
    assert clean_for_speech("Leo's turn — 5 points!") == "Leo's turn — 5 points!"
    assert clean_for_speech("👍") == ""


def test_clean_transcript_drops_sound_tags():
    assert clean_transcript(" [BLANK_AUDIO] ") == ""
    assert clean_transcript(" What's for dinner? (door closes)") == "What's for dinner?"
    assert clean_transcript("♪♪ *music*  hello  there") == "hello there"


@pytest.fixture
def fake_aplay(tmp_path, monkeypatch):
    """An `aplay` on PATH that 'plays' stdin into a file, slowly."""
    out = tmp_path / "played.raw"
    args = tmp_path / "args.txt"
    script = tmp_path / "bin" / "aplay"
    script.parent.mkdir()
    script.write_text(
        f"#!{sys.executable}\n"
        "import sys, time\n"
        f"open({str(args)!r}, 'w').write(' '.join(sys.argv[1:]))\n"
        f"with open({str(out)!r}, 'wb') as f:\n"
        "    while chunk := sys.stdin.buffer.read(4410):\n"
        "        f.write(chunk); f.flush(); time.sleep(0.01)\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{script.parent}{os.pathsep}{os.environ['PATH']}")
    return out, args


def test_aplay_player_plays_everything(fake_aplay):
    out, args = fake_aplay
    audio = pcm.tone(300, 0.5, rate=22050)
    player = make_player("auto", "default:CARD=vc4hdmi0")
    assert isinstance(player, AplayPlayer)
    player.play(22050, iter([audio[:1000], audio[1000:]]), threading.Event())
    assert out.read_bytes() == audio
    assert args.read_text() == "-q -t raw -f S16_LE -c 1 -r 22050 -D default:CARD=vc4hdmi0"


def test_aplay_player_stops_quickly(fake_aplay):
    out, _ = fake_aplay
    player = AplayPlayer()
    stop = threading.Event()
    long_audio = pcm.silence(30, rate=22050)  # ~13 s of fake playback

    def chunks():
        for i in range(0, len(long_audio), 8820):
            yield long_audio[i : i + 8820]

    threading.Timer(0.3, lambda: (stop.set(), player.abort())).start()
    started = time.monotonic()
    player.play(22050, chunks(), stop)
    assert time.monotonic() - started < 2.0
    assert len(out.read_bytes()) < len(long_audio)


def test_aplay_player_reports_failures(tmp_path, monkeypatch):
    script = tmp_path / "aplay"
    script.write_text("#!/bin/sh\n"
                      "echo \"ALSA lib confmisc.c:855:(parse_card) cannot find card '9'\" >&2\n"
                      "echo 'aplay: main:831: audio open error: No such device' >&2\n"
                      "exit 1\n")
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}{os.pathsep}{os.environ['PATH']}")
    with pytest.raises(AudioError) as err:
        AplayPlayer("hw:9").play(16000, iter([pcm.silence(0.1)]), threading.Event())
    assert str(err.value) == "aplay failed: aplay: main:831: audio open error: No such device"


def test_aplay_player_closes_aplay_if_synthesis_fails(fake_aplay):
    def broken():
        yield pcm.silence(0.05)
        raise RuntimeError("model crashed")

    with pytest.raises(RuntimeError, match="model crashed"):
        AplayPlayer().play(16000, broken(), threading.Event())


def test_create_synth_off_and_missing(tmp_path, monkeypatch):
    assert create_synth(TtsConfig(engine="off"), tmp_path) is None
    monkeypatch.setitem(sys.modules, "piper", None)
    monkeypatch.setenv("PATH", str(tmp_path))  # no espeak-ng either
    assert create_synth(TtsConfig(), tmp_path) is None


@pytest.mark.skipif(not shutil.which("espeak-ng"), reason="espeak-ng not installed")
def test_espeak_fallback_synthesizes_and_plays(fake_aplay, tmp_path, monkeypatch):
    out, args = fake_aplay
    monkeypatch.setitem(sys.modules, "piper", None)  # force the fallback
    synth = create_synth(TtsConfig(), tmp_path)
    assert isinstance(synth, EspeakSynth)
    rate, chunks = synth.stream("-n is not an option. Dinner is at six.")
    audio = b"".join(chunks)
    assert rate == 22050
    assert len(audio) > rate * 2 * 0.5  # at least half a second of speech
    assert pcm.rms(audio) > 0.01
    Speaker(synth, AplayPlayer()).speak("Tacos **tonight**!", threading.Event())
    assert "-r 22050" in args.read_text()
    assert pcm.rms(out.read_bytes()) > 0.01

"""Text to speech: Piper (a natural neural voice, run locally), falling back
to the espeak-ng command line."""

from __future__ import annotations

import logging
import re
import shutil
import subprocess
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import Protocol

from .audio import Player
from .config import TtsConfig
from .pcm import parse_wav, pick_channel

log = logging.getLogger(__name__)

_URL = re.compile(r"https?://\S+")
_EMPHASIS = re.compile(r"(\*\*|__|\*)(\S(?:.*?\S)?)\1")
_LIST_MARK = re.compile(r"^\s*(?:#+|[-*•]|\d+[.)])\s+")
_EMOJI = re.compile("[\U0001f000-\U0001faff\u2600-\u27bf\u2b00-\u2bff\ufe0f\u200d]")


def clean_for_speech(text: str) -> str:
    """Strip what reads badly aloud: markdown, emoji, URLs. List items become
    short sentences."""
    text = _URL.sub("a link", text).replace("`", "")
    lines = [_EMOJI.sub("", _EMPHASIS.sub(r"\2", _LIST_MARK.sub("", line))).strip()
             for line in text.splitlines()]
    lines = [line for line in lines if line]
    if len(lines) > 1:
        # A pause between items instead of running them together.
        lines = [line if line[-1] in ".!?,;:" else line + "." for line in lines]
    return " ".join(" ".join(lines).split())


class Synthesizer(Protocol):
    engine: str

    def stream(self, text: str) -> tuple[int, Iterator[bytes]]:
        """(sample rate, 16-bit mono chunks) for `text`."""
        ...


def piper_voice_path(voice: str, data_dir: Path) -> Path:
    path = Path(voice).expanduser()
    if path.suffix == ".onnx":
        return path if path.is_absolute() or path.exists() else data_dir / "piper" / path
    return data_dir / "piper" / f"{voice}.onnx"


class PiperSynth:
    engine = "piper"

    def __init__(self, cfg: TtsConfig, data_dir: Path) -> None:
        from piper import PiperVoice  # optional: the `tts` extra

        path = piper_voice_path(cfg.voice, data_dir)
        if not path.exists():
            raise FileNotFoundError(
                f"voice {path} not found (run: python -m homeos_voice --download-models)")
        self._voice = PiperVoice.load(str(path))
        self.rate = int(self._voice.config.sample_rate)
        self._speed = cfg.speed
        self._syn = None
        try:
            from piper import SynthesisConfig  # piper-tts 1.3+

            self._syn = SynthesisConfig(length_scale=1.0 / cfg.speed, volume=cfg.volume)
        except ImportError:
            pass
        log.info("spoken replies: piper, voice %s", path.name)

    def stream(self, text: str) -> tuple[int, Iterator[bytes]]:
        if self._syn is not None:
            chunks = (chunk.audio_int16_bytes
                      for chunk in self._voice.synthesize(text, syn_config=self._syn))
        else:  # piper-tts 1.2
            chunks = self._voice.synthesize_stream_raw(text, length_scale=1.0 / self._speed)
        return self.rate, iter(chunks)


class EspeakSynth:
    engine = "espeak-ng"

    def __init__(self, cfg: TtsConfig) -> None:
        exe = shutil.which("espeak-ng") or shutil.which("espeak")
        if exe is None:
            raise FileNotFoundError("espeak-ng isn't installed (apt install espeak-ng)")
        words_per_minute = round(165 * cfg.speed)
        amplitude = min(200, round(100 * cfg.volume))
        self._cmd = [exe, "--stdout", "-v", cfg.espeak_voice,
                     "-s", str(words_per_minute), "-a", str(amplitude)]
        log.info("spoken replies: espeak-ng, voice %s", cfg.espeak_voice)

    def stream(self, text: str) -> tuple[int, Iterator[bytes]]:
        # Text goes in on stdin so a leading "-" can't be read as an option.
        result = subprocess.run(self._cmd, input=text.encode(), capture_output=True,
                                timeout=60, check=False)
        if result.returncode != 0:
            message = result.stderr.decode(errors="replace").strip()
            raise RuntimeError(f"espeak-ng failed: {message}")
        rate, channels, pcm = parse_wav(result.stdout)
        return rate, iter([pick_channel(pcm, channels, 0)])


def create_synth(cfg: TtsConfig, data_dir: Path) -> Synthesizer | None:
    """The configured engine, or None (with a logged reason) if there is none."""
    if cfg.engine == "off":
        log.info("spoken replies are off (tts.engine = off)")
        return None
    problems = []
    if cfg.engine in ("auto", "piper"):
        try:
            return PiperSynth(cfg, data_dir)
        except ImportError:
            problems.append("piper isn't installed")
        except Exception as e:
            problems.append(f"piper: {e}")
    if cfg.engine in ("auto", "espeak"):
        if problems:
            log.warning("%s; falling back to espeak-ng", problems[0])
        try:
            return EspeakSynth(cfg)
        except Exception as e:
            problems.append(str(e))
    log.warning("spoken replies unavailable: %s", "; ".join(problems))
    return None


class Speaker:
    """Speaks one text at a time through a player; `abort` cuts it short."""

    def __init__(self, synth: Synthesizer, player: Player) -> None:
        self.synth = synth
        self.player = player

    def speak(self, text: str, stop: threading.Event) -> None:
        text = clean_for_speech(text)
        if not text or stop.is_set():
            return
        rate, chunks = self.synth.stream(text)
        self.player.play(rate, chunks, stop)

    def abort(self) -> None:
        self.player.abort()

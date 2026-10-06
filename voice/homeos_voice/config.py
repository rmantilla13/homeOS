"""Settings, read from TOML (default /etc/homeos/voice.toml). Every key is
optional; voice/voice.example.toml documents them all."""

from __future__ import annotations

import dataclasses
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_PATH = "/etc/homeos/voice.toml"
LOG_LEVELS = ("debug", "info", "warning", "error")


class ConfigError(Exception):
    """The config file is missing, unreadable or has a bad value."""


def _default_data_dir() -> str:
    # Models and the remembered wake-word switch live in the service user's home.
    return os.path.join(os.environ.get("XDG_DATA_HOME") or "~/.local/share", "homeos-voice")


# A device can be picked by sounddevice index or by part of its name.
_DEVICE = {"types": (str, int)}


@dataclass
class ServerConfig:
    host: str = "127.0.0.1"
    port: int = 8765


@dataclass
class AudioConfig:
    input_device: str | int = field(default="", metadata=_DEVICE)
    input_channel: int = 0
    output: str = "auto"
    output_device: str | int = field(default="", metadata=_DEVICE)


@dataclass
class WakewordConfig:
    enabled: bool = True
    model: str = "hey_jarvis"
    name: str = ""
    threshold: float = 0.5
    refractory: float = 2.0
    resume_delay: float = 0.5
    inference_framework: str = "onnx"


@dataclass
class VadConfig:
    engine: str = "auto"
    aggressiveness: int = 2
    silence: float = 0.7
    max_length: float = 8.0
    no_speech: float = 4.0
    energy_threshold: float = 0.015


@dataclass
class SttConfig:
    model: str = "base.en"
    compute_type: str = "int8"
    language: str = "en"
    beam_size: int = 1
    threads: int = 0
    initial_prompt: str = ""


@dataclass
class TtsConfig:
    engine: str = "auto"
    voice: str = "en_US-amy-medium"
    speed: float = 1.0
    volume: float = 1.0
    espeak_voice: str = "en-us"


@dataclass
class Config:
    log_level: str = "info"
    data_dir: str = field(default_factory=_default_data_dir)
    server: ServerConfig = field(default_factory=ServerConfig)
    audio: AudioConfig = field(default_factory=AudioConfig)
    wakeword: WakewordConfig = field(default_factory=WakewordConfig)
    vad: VadConfig = field(default_factory=VadConfig)
    stt: SttConfig = field(default_factory=SttConfig)
    tts: TtsConfig = field(default_factory=TtsConfig)
    # Not a setting: unknown keys found while parsing, logged at startup.
    warnings: list[str] = field(default_factory=list, repr=False, compare=False)

    @property
    def data_path(self) -> Path:
        return Path(self.data_dir).expanduser()


_SECTIONS = ("server", "audio", "wakeword", "vad", "stt", "tts")
_TOP_LEVEL = ("log_level", "data_dir")


def load_config(path: str | os.PathLike[str] | None = None) -> Config:
    """Read `path`, or the default path if it exists, else return defaults."""
    if path is None:
        if not os.path.exists(DEFAULT_PATH):
            return Config()
        path = DEFAULT_PATH
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        raise ConfigError(f"config file not found: {path}") from None
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from None
    except OSError as e:
        raise ConfigError(f"{path}: {e.strerror}") from None
    return parse_config(data)


def loads_config(text: str) -> Config:
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(str(e)) from None
    return parse_config(data)


def parse_config(data: dict[str, Any]) -> Config:
    cfg = Config()
    for key, value in data.items():
        if key in _SECTIONS:
            if not isinstance(value, dict):
                raise ConfigError(f"[{key}] must be a table")
            _apply_section(getattr(cfg, key), key, value, cfg.warnings)
        elif key in _TOP_LEVEL:
            if not isinstance(value, str):
                raise ConfigError(f"{key} must be a string, got {value!r}")
            setattr(cfg, key, value)
        else:
            cfg.warnings.append(f"unknown key '{key}' ignored")
    cfg.log_level = cfg.log_level.lower()
    validate(cfg)
    return cfg


def _apply_section(obj: Any, section: str, table: dict[str, Any], warnings: list[str]) -> None:
    fields = {f.name: f for f in dataclasses.fields(obj)}
    for key, value in table.items():
        f = fields.get(key)
        if f is None:
            warnings.append(f"unknown key '{section}.{key}' ignored")
            continue
        setattr(obj, key, _coerce(f"{section}.{key}", value, f.default, f.metadata))


def _coerce(name: str, value: Any, default: Any, metadata: Any) -> Any:
    # bool is a subclass of int, so it's excluded from every numeric check.
    if isinstance(value, bool):
        if isinstance(default, bool):
            return value
        raise ConfigError(f"{name} must not be true/false, got {value!r}")
    allowed = metadata.get("types")
    if allowed:
        if isinstance(value, allowed):
            return value
        raise ConfigError(f"{name} must be a device name or index, got {value!r}")
    if isinstance(default, bool):
        expected = "true or false"
    elif isinstance(default, int):
        if isinstance(value, int):
            return value
        expected = "a whole number"
    elif isinstance(default, float):
        if isinstance(value, (int, float)):
            return float(value)
        expected = "a number"
    else:
        if isinstance(value, str):
            return value
        expected = "a string"
    raise ConfigError(f"{name} must be {expected}, got {value!r}")


def validate(cfg: Config) -> None:
    problems: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            problems.append(message)

    check(cfg.log_level in LOG_LEVELS, f"log_level must be one of {', '.join(LOG_LEVELS)}")
    check(bool(cfg.data_dir.strip()), "data_dir can't be empty")
    check(bool(cfg.server.host.strip()), "server.host can't be empty")
    check(0 <= cfg.server.port <= 65535, "server.port must be 0-65535")
    check(cfg.audio.output in ("auto", "aplay", "sounddevice"),
          "audio.output must be auto, aplay or sounddevice")
    check(cfg.audio.input_channel >= 0, "audio.input_channel must be 0 or more")
    w = cfg.wakeword
    check(bool(w.model.strip()), "wakeword.model can't be empty")
    check(0.0 < w.threshold < 1.0, "wakeword.threshold must be between 0 and 1")
    check(w.refractory >= 0, "wakeword.refractory must be 0 or more")
    check(w.resume_delay >= 0, "wakeword.resume_delay must be 0 or more")
    check(w.inference_framework in ("onnx", "tflite"),
          "wakeword.inference_framework must be onnx or tflite")
    v = cfg.vad
    check(v.engine in ("auto", "webrtc", "energy"), "vad.engine must be auto, webrtc or energy")
    check(0 <= v.aggressiveness <= 3, "vad.aggressiveness must be 0-3")
    check(v.silence > 0, "vad.silence must be more than 0")
    check(v.max_length > 0, "vad.max_length must be more than 0")
    check(v.no_speech > 0, "vad.no_speech must be more than 0")
    check(0.0 < v.energy_threshold < 1.0, "vad.energy_threshold must be between 0 and 1")
    s = cfg.stt
    check(bool(s.model.strip()), "stt.model can't be empty")
    check(s.beam_size >= 1, "stt.beam_size must be 1 or more")
    check(s.threads >= 0, "stt.threads must be 0 (automatic) or more")
    t = cfg.tts
    check(t.engine in ("auto", "piper", "espeak", "off"),
          "tts.engine must be auto, piper, espeak or off")
    check(t.speed > 0, "tts.speed must be more than 0")
    check(0 < t.volume <= 4, "tts.volume must be more than 0 (1.0 is normal)")
    if problems:
        raise ConfigError("; ".join(problems))

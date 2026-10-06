"""Config parsing and the command line."""

from __future__ import annotations

import dataclasses
import re
from pathlib import Path

import pytest

from homeos_voice import __main__ as cli
from homeos_voice import config as config_module
from homeos_voice.config import Config, ConfigError, load_config, loads_config

EXAMPLE = Path(__file__).resolve().parents[1] / "voice.example.toml"


def uncommented_example() -> str:
    """The example with every `#key = value` line switched on."""
    return re.sub(r"(?m)^#(\w+ = )", r"\1", EXAMPLE.read_text())


def test_defaults_match_the_spec(monkeypatch):
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    cfg = Config()
    assert (cfg.server.host, cfg.server.port) == ("127.0.0.1", 8765)
    assert cfg.wakeword.model == "hey_jarvis"
    assert cfg.wakeword.threshold == 0.5 and cfg.wakeword.refractory == 2.0
    assert cfg.vad.aggressiveness == 2
    assert (cfg.vad.silence, cfg.vad.max_length, cfg.vad.no_speech) == (0.7, 8.0, 4.0)
    assert (cfg.stt.model, cfg.stt.compute_type, cfg.stt.language) == ("base.en", "int8", "en")
    assert cfg.tts.voice == "en_US-amy-medium"
    assert cfg.data_path == Path("~/.local/share/homeos-voice").expanduser()


def test_empty_file_gives_defaults():
    assert loads_config("") == Config()


def test_example_is_all_defaults_when_uncommented(monkeypatch):
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    assert loads_config(EXAMPLE.read_text()) == Config()  # as shipped: all commented out
    cfg = loads_config(uncommented_example())
    assert cfg.warnings == []
    assert cfg == Config()


def test_example_documents_every_setting():
    text = uncommented_example()
    documented = set(re.findall(r"(?m)^(\w+) = ", text))
    expected = {"log_level", "data_dir"}
    for section in ("server", "audio", "wakeword", "vad", "stt", "tts"):
        expected |= {f.name for f in dataclasses.fields(getattr(Config(), section))}
    assert documented == expected


def test_values_are_read_and_ints_become_floats():
    cfg = loads_config("""
        log_level = "DEBUG"
        data_dir = "/var/lib/homeos-voice"
        [server]
        port = 9000
        [audio]
        input_device = 2
        output_device = "default:CARD=vc4hdmi0"
        [wakeword]
        enabled = false
        model = "/opt/models/hey_homeos.onnx"
        name = "Hey homeOS"
        threshold = 0.6
        refractory = 3
        [vad]
        silence = 1
        [stt]
        initial_prompt = "Leo, Maya"
        [tts]
        engine = "espeak"
    """)
    assert cfg.log_level == "debug"
    assert cfg.data_path == Path("/var/lib/homeos-voice")
    assert cfg.server.port == 9000
    assert cfg.audio.input_device == 2
    assert cfg.audio.output_device == "default:CARD=vc4hdmi0"
    assert cfg.wakeword.enabled is False
    assert cfg.wakeword.name == "Hey homeOS"
    assert cfg.wakeword.refractory == 3.0 and isinstance(cfg.wakeword.refractory, float)
    assert cfg.vad.silence == 1.0 and isinstance(cfg.vad.silence, float)
    assert cfg.stt.initial_prompt == "Leo, Maya"
    assert cfg.tts.engine == "espeak"


def test_unknown_keys_are_warnings_not_errors():
    cfg = loads_config("""
        colour = "blue"
        [wakeword]
        treshold = 0.7
        [extras]
        a = 1
    """)
    assert cfg.wakeword.threshold == 0.5
    assert cfg.warnings == [
        "unknown key 'colour' ignored",
        "unknown key 'wakeword.treshold' ignored",
        "unknown key 'extras' ignored",
    ]


@pytest.mark.parametrize("text, message", [
    ("[server]\nport = '8765'", "server.port must be a whole number"),
    ("[server]\nport = 8765.5", "server.port must be a whole number"),
    ("[server]\nport = 70000", "server.port must be 0-65535"),
    ("[wakeword]\nenabled = 1", "wakeword.enabled must be true or false"),
    ("[wakeword]\nthreshold = true", "must not be true/false"),
    ("[wakeword]\nthreshold = 1.5", "wakeword.threshold must be between 0 and 1"),
    ("[vad]\naggressiveness = 4", "vad.aggressiveness must be 0-3"),
    ("[vad]\nsilence = 0", "vad.silence must be more than 0"),
    ("[vad]\nengine = 'silero'", "vad.engine must be"),
    ("[audio]\noutput = 'pulse'", "audio.output must be"),
    ("[audio]\ninput_device = 1.5", "audio.input_device must be a device name or index"),
    ("[stt]\nbeam_size = 0", "stt.beam_size must be 1 or more"),
    ("[tts]\nengine = 'say'", "tts.engine must be"),
    ("log_level = 'loud'", "log_level must be one of"),
    ("server = 1", "[server] must be a table"),
    ("[server\nport = 1", "Expected ']'"),
])
def test_bad_values_are_errors(text, message):
    with pytest.raises(ConfigError, match=re.escape(message)):
        loads_config(text)


def test_problems_are_reported_together():
    with pytest.raises(ConfigError) as err:
        loads_config("[vad]\nsilence = -1\nmax_length = 0")
    assert "vad.silence" in str(err.value) and "vad.max_length" in str(err.value)


def test_load_config_paths(tmp_path, monkeypatch):
    path = tmp_path / "voice.toml"
    path.write_text("[server]\nport = 9100\n")
    assert load_config(path).server.port == 9100
    with pytest.raises(ConfigError, match="not found"):
        load_config(tmp_path / "missing.toml")
    # With no path, a missing default file just means defaults...
    monkeypatch.setattr(config_module, "DEFAULT_PATH", str(tmp_path / "nope.toml"))
    assert load_config() == Config()
    # ...and an existing one is read.
    monkeypatch.setattr(config_module, "DEFAULT_PATH", str(path))
    assert load_config().server.port == 9100


def test_cli_rejects_a_bad_config(tmp_path, capsys):
    bad = tmp_path / "bad.toml"
    bad.write_text("[vad]\naggressiveness = 9\n")
    assert cli.main(["--config", str(bad), "--simulate"]) == 2
    assert "vad.aggressiveness" in capsys.readouterr().err
    assert cli.main(["--config", str(tmp_path / "missing.toml")]) == 2
    assert cli.main(["--config", str(EXAMPLE), "--port", "99999"]) == 2


def test_cli_options_parse():
    args = cli.build_parser().parse_args(
        ["--config", "/x.toml", "--simulate", "--host", "0.0.0.0", "--port", "9", "--log-level",
         "debug"])
    assert (args.config, args.simulate, args.host, args.port, args.log_level) == (
        "/x.toml", True, "0.0.0.0", 9, "debug")

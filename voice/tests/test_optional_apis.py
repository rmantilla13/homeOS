"""Our calls into the optional libraries match their installed signatures.
Each test is skipped when its extra isn't installed (the core test run), and
no models are needed or downloaded."""

from __future__ import annotations

import inspect
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from homeos_voice.config import SttConfig
from homeos_voice.pcm import tone
from homeos_voice.stt import Transcriber


def test_faster_whisper_calls():
    fw = pytest.importorskip("faster_whisper")
    init = inspect.signature(fw.WhisperModel.__init__)
    init.bind(None, "base.en", device="cpu", compute_type="int8", cpu_threads=0,
              download_root="/tmp/whisper", local_files_only=True)

    calls = {}

    class Recorder:
        def transcribe(self, audio, **kwargs):
            calls.update(kwargs, audio=audio)
            return iter([SimpleNamespace(text=" Dinner's at six. "),
                         SimpleNamespace(text="[BLANK_AUDIO]")]), None

    t = Transcriber(SttConfig(initial_prompt="Leo, Maya"), Path("/tmp"))
    t._model = Recorder()
    assert t.transcribe(tone(200, 0.5)) == "Dinner's at six."
    audio = calls.pop("audio")
    assert audio.dtype.name == "float32" and len(audio) == 8000 and abs(audio).max() <= 1.0
    inspect.signature(fw.WhisperModel.transcribe).bind(None, audio, **calls)
    assert calls["language"] == "en" and calls["initial_prompt"] == "Leo, Maya"


def test_piper_calls():
    piper = pytest.importorskip("piper")
    inspect.signature(piper.PiperVoice.load).bind("/tmp/en_US-amy-medium.onnx")
    syn = piper.SynthesisConfig(length_scale=1.0, volume=1.0)
    inspect.signature(piper.PiperVoice.synthesize).bind(None, "Hello", syn_config=syn)
    assert isinstance(inspect.getattr_static(piper.AudioChunk, "audio_int16_bytes"), property)
    help_text = subprocess.run([sys.executable, "-m", "piper.download_voices", "--help"],
                               capture_output=True, text=True, check=True).stdout
    assert "--data-dir" in help_text


def test_openwakeword_calls():
    pytest.importorskip("numpy")
    try:
        from openwakeword.model import Model
        from openwakeword.utils import AudioFeatures, download_models
    except ImportError:
        pytest.skip("openwakeword not installed")
    # Model.__init__ hides its signature behind a decorator; check the source.
    source = inspect.getsource(Model)
    assert "wakeword_models" in source and "inference_framework" in source
    inspect.signature(AudioFeatures.__init__).bind(
        None, melspec_model_path="m.onnx", embedding_model_path="e.onnx",
        inference_framework="onnx")
    inspect.signature(download_models).bind(model_names=["hey_jarvis"], target_directory="/tmp")
    assert callable(Model.predict) and callable(Model.reset)


def test_missing_wakeword_model_is_a_clear_error(tmp_path):
    pytest.importorskip("numpy")
    pytest.importorskip("openwakeword")
    from homeos_voice.wakeword import WakeWordDetector

    with pytest.raises(FileNotFoundError, match="wake word model not found"):
        WakeWordDetector("hey_homeos.onnx", data_dir=tmp_path)
    with pytest.raises(ValueError, match="unknown wake word model 'hey_toaster'"):
        WakeWordDetector("hey_toaster", data_dir=tmp_path)
    # The wheel ships no models; built-ins arrive with --download-models.
    with pytest.raises(FileNotFoundError, match="isn't downloaded"):
        WakeWordDetector("hey_jarvis", data_dir=tmp_path)


def test_sounddevice_calls():
    try:
        import sounddevice as sd
    except (ImportError, OSError):
        pytest.skip("sounddevice or PortAudio not installed")
    inspect.signature(sd.RawInputStream.__init__).bind(
        None, device=0, samplerate=16000, channels=1, dtype="int16", blocksize=1280,
        callback=lambda *a: None)
    inspect.signature(sd.RawOutputStream.__init__).bind(
        None, samplerate=22050, channels=1, dtype="int16", device=None)
    inspect.signature(sd.check_input_settings).bind(
        device=0, samplerate=16000, channels=1, dtype="int16")


def test_resampler_makes_80ms_frames_at_16k():
    pytest.importorskip("numpy")
    from homeos_voice.audio import make_resampler
    from homeos_voice.pcm import FRAME_BYTES, rms

    for rate in (48000, 44100, 32000, 22050, 8000):
        block = tone(440, 0.08, amplitude=0.5, rate=rate)
        out = make_resampler(rate)(block)
        assert len(out) == FRAME_BYTES, rate
        assert rms(out) == pytest.approx(0.5 / 2**0.5, rel=0.1), rate

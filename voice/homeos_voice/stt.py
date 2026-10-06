"""Speech to text with faster-whisper, on the device's CPU."""

from __future__ import annotations

import logging
import re
import time
from pathlib import Path

from .config import SttConfig
from .pcm import SAMPLE_RATE

log = logging.getLogger(__name__)

# Whisper writes sound descriptions such as "[BLANK_AUDIO]" or "(door closes)".
_NON_SPEECH = re.compile(r"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+")


def clean_transcript(text: str) -> str:
    text = _NON_SPEECH.sub(" ", text)
    return " ".join(text.split())


class Transcriber:
    """Loads the Whisper model once and transcribes one utterance at a time."""

    def __init__(self, cfg: SttConfig, data_dir: Path) -> None:
        self.cfg = cfg
        self.download_root = data_dir / "whisper"
        self._model = None

    def load(self, allow_download: bool = False) -> None:
        """Load the model. While running it must already be on disk
        (`--download-models`), so the service never reaches the network."""
        from faster_whisper import WhisperModel  # optional: the `stt` extra

        started = time.monotonic()
        try:
            self._model = WhisperModel(
                self.cfg.model,
                device="cpu",
                compute_type=self.cfg.compute_type,
                cpu_threads=self.cfg.threads,
                download_root=str(self.download_root),
                local_files_only=not allow_download,
            )
        except Exception as e:
            if allow_download:
                raise
            raise RuntimeError(f"model {self.cfg.model} isn't downloaded or won't load "
                               f"(run: python -m homeos_voice --download-models): {e}") from e
        log.info("speech-to-text model %s (%s) loaded in %.1f s",
                 self.cfg.model, self.cfg.compute_type, time.monotonic() - started)

    def transcribe(self, pcm: bytes) -> str:
        """16 kHz mono int16 audio in, text out ("" if nothing was said)."""
        import numpy as np

        if self._model is None:
            raise RuntimeError("speech-to-text model isn't loaded")
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        started = time.monotonic()
        segments, _info = self._model.transcribe(
            audio,
            language=self.cfg.language or None,
            beam_size=self.cfg.beam_size,
            # The endpointer already cut the audio to one utterance.
            vad_filter=False,
            condition_on_previous_text=False,
            without_timestamps=True,
            initial_prompt=self.cfg.initial_prompt or None,
        )
        text = clean_transcript(" ".join(s.text for s in segments))
        log.info("transcribed %.1f s of audio in %.1f s",
                 len(audio) / SAMPLE_RATE, time.monotonic() - started)
        return text


def download_model(cfg: SttConfig, data_dir: Path) -> None:
    """Fetch the model (and check that it loads)."""
    Transcriber(cfg, data_dir).load(allow_download=True)

"""The WebSocket protocol between this service and the display: JSON text
frames, one object per frame, each with a `type`. See PLATFORM_SPEC.md §4."""

from __future__ import annotations

import json
from typing import Any

from . import PROTOCOL_VERSION

STATES = ("idle", "listening", "transcribing", "speaking")
WAKE_SOURCES = ("wakeword", "button")
CLIENT_TYPES = ("listen", "cancel", "speak", "stop_speaking", "set")
# A speak id is echoed in `spoken` to every client.
MAX_ID_CHARS = 200


class ProtocolError(ValueError):
    """A client sent something we can't act on. The message goes back to it."""


# Server → client


def hello(*, wakeword: bool, wakeword_name: str, tts: bool, stt: bool) -> dict[str, Any]:
    return {
        "type": "hello",
        "version": PROTOCOL_VERSION,
        "wakeword": wakeword,
        "wakeword_name": wakeword_name,
        "tts": tts,
        "stt": stt,
    }


def state(value: str) -> dict[str, Any]:
    assert value in STATES, value
    return {"type": "state", "state": value}


def wake(source: str) -> dict[str, Any]:
    assert source in WAKE_SOURCES, source
    return {"type": "wake", "source": source}


def level(rms: float) -> dict[str, Any]:
    return {"type": "level", "rms": round(min(1.0, max(0.0, rms)), 3)}


def transcript(text: str) -> dict[str, Any]:
    return {"type": "transcript", "text": text, "final": True}


def spoken(speech_id: str) -> dict[str, Any]:
    return {"type": "spoken", "id": speech_id}


def error(message: str) -> dict[str, Any]:
    return {"type": "error", "message": message}


def encode(message: dict[str, Any]) -> str:
    text = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
    try:
        text.encode()
    except UnicodeEncodeError:
        # A lone surrogate (in a client's id, say) can't be sent as UTF-8; escape it.
        text = json.dumps(message, separators=(",", ":"))
    return text


# Client → server


def parse_client_message(raw: str | bytes) -> dict[str, Any]:
    """Decode and check one client frame. Returns the message with its fields
    normalised; raises ProtocolError with a short reason otherwise."""
    if isinstance(raw, bytes):
        raise ProtocolError("expected a JSON text frame")
    try:
        msg = json.loads(raw)
    except (json.JSONDecodeError, RecursionError):  # RecursionError: absurdly deep nesting
        raise ProtocolError("not valid JSON") from None
    if not isinstance(msg, dict):
        raise ProtocolError("expected a JSON object")
    kind = msg.get("type")
    if kind not in CLIENT_TYPES:
        raise ProtocolError(f"unknown message type {kind!r}")

    if kind == "speak":
        text = msg.get("text")
        if not isinstance(text, str):
            raise ProtocolError("speak needs a text string")
        speech_id = msg.get("id")
        if isinstance(speech_id, bool) or not isinstance(speech_id, (str, int, type(None))):
            raise ProtocolError("speak id must be a string")
        if speech_id is not None:
            speech_id = str(speech_id)
            if len(speech_id) > MAX_ID_CHARS:
                raise ProtocolError(f"speak id must be at most {MAX_ID_CHARS} characters")
        return {"type": "speak", "text": text, "id": speech_id}
    if kind == "set":
        enabled = msg.get("wakeword_enabled")
        if not isinstance(enabled, bool):
            raise ProtocolError("set needs wakeword_enabled: true or false")
        return {"type": "set", "wakeword_enabled": enabled}
    return {"type": kind}

"""Shared test helpers: a running service, a recording client, test audio."""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
from array import array
from collections.abc import AsyncIterator, Callable
from typing import Any

from websockets.asyncio.client import ClientConnection, connect

from homeos_voice.pcm import SAMPLE_RATE, to_bytes
from homeos_voice.service import VoiceService
from homeos_voice.simulate import SimBackend


def fast_sim(**kwargs: Any) -> SimBackend:
    """Simulate mode with short delays (levels keep their real 15/s pace)."""
    options = {"transcribe_time": 0.05, "word_time": 0.01}
    options.update(kwargs)
    return SimBackend(**options)


@contextlib.asynccontextmanager
async def running(backend: Any = None, **service_options: Any) -> AsyncIterator[
        tuple[VoiceService, Any, str]]:
    """A VoiceService on a free localhost port; yields (service, backend, url)."""
    backend = backend or fast_sim()
    service_options.setdefault("refractory", 0.0)
    service_options.setdefault("resume_delay", 0.0)
    service = VoiceService(backend, **service_options)
    server = await service.serve("127.0.0.1", 0)
    await backend.start(service)
    port = server.sockets[0].getsockname()[1]
    try:
        yield service, backend, f"ws://127.0.0.1:{port}"
    finally:
        server.close()
        await service.close()
        await server.wait_closed()
        await backend.close()


Match = dict[str, Any] | Callable[[dict[str, Any]], bool]


def _matches(msg: dict[str, Any], want: Match) -> bool:
    if callable(want):
        return want(msg)
    return all(msg.get(k) == v for k, v in want.items())


class Client:
    """A test client that records everything it receives."""

    def __init__(self, ws: ClientConnection) -> None:
        self.ws = ws
        self.received: list[dict[str, Any]] = []

    async def send(self, **msg: Any) -> None:
        await self.ws.send(json.dumps(msg))

    async def recv(self, timeout: float = 3.0) -> dict[str, Any]:
        msg = json.loads(await asyncio.wait_for(self.ws.recv(), timeout))
        self.received.append(msg)
        return msg

    async def until(self, want: Match, timeout: float = 5.0) -> list[dict[str, Any]]:
        """Messages up to and including the first one matching `want`."""
        got = []
        async with asyncio.timeout(timeout):
            while True:
                msg = await self.recv(timeout)
                got.append(msg)
                if _matches(msg, want):
                    return got

    async def quiet(self, within: float = 0.3) -> list[dict[str, Any]]:
        """Whatever arrives in the next `within` seconds (usually nothing)."""
        got = []
        with contextlib.suppress(TimeoutError):
            async with asyncio.timeout(within):
                while True:
                    got.append(await self.recv(within))
        return got


@contextlib.asynccontextmanager
async def client(url: str, *, greeted: bool = True) -> AsyncIterator[Client]:
    """Connect; by default also consume the hello and initial state."""
    async with connect(url) as ws:
        c = Client(ws)
        if greeted:
            await c.until({"type": "state"})
        yield c


def types(messages: list[dict[str, Any]], *, levels: bool = False) -> list[str]:
    """Message types in order, levels left out unless asked for."""
    return [m["type"] for m in messages if levels or m["type"] != "level"]


def vowel(seconds: float, amplitude: float = 0.3, f0: float = 130.0) -> bytes:
    """A crude synthetic vowel (harmonics of f0 shaped by three formants),
    which webrtcvad accepts as speech, unlike a pure tone."""
    formants = ((700, 130), (1220, 70), (2600, 160))
    harmonics = []
    for k in range(1, 30):
        f = k * f0
        gain = sum(1 / (1 + ((f - c) / bw) ** 2) for c, bw in formants) / math.sqrt(k)
        harmonics.append((2 * math.pi * f / SAMPLE_RATE, gain))
    n = int(SAMPLE_RATE * seconds)
    raw = [sum(g * math.sin(w * i) for w, g in harmonics) for i in range(n)]
    peak = max(abs(x) for x in raw) or 1.0
    return to_bytes(array("h", (int(amplitude * 32767 * x / peak) for x in raw)))

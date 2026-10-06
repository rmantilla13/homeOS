"""`python -m homeos_voice --simulate` as a real process, driven over stdin
and a WebSocket, the way the display's simulator check uses it."""

from __future__ import annotations

import asyncio
import json
import re
import signal
import subprocess
import sys
import threading
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest
from helpers import Client, types
from websockets.asyncio.client import connect
from websockets.exceptions import InvalidStatus


@asynccontextmanager
async def service_process(tmp_path) -> AsyncIterator[tuple[subprocess.Popen[str], str]]:
    config = tmp_path / "voice.toml"
    config.write_text('[wakeword]\nname = "Hey Ohana"\n')
    proc = subprocess.Popen(
        [sys.executable, "-m", "homeos_voice", "--simulate", "--config", str(config),
         "--port", "0", "--log-level", "info"],
        stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    try:
        url = await asyncio.wait_for(asyncio.to_thread(_wait_for_url, proc), 15)
        # Keep reading the log so the service never blocks on a full pipe.
        threading.Thread(target=proc.stderr.read, daemon=True).start()  # type: ignore[union-attr]
        yield proc, url
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()


def _wait_for_url(proc: subprocess.Popen[str]) -> str:
    assert proc.stderr is not None
    for line in proc.stderr:
        match = re.search(r"listening on (ws://\S+)", line)
        if match:
            return match.group(1)
    raise AssertionError(f"service exited early with {proc.wait()}")


def send_line(proc: subprocess.Popen[str], line: str) -> None:
    assert proc.stdin is not None
    proc.stdin.write(line + "\n")
    proc.stdin.flush()


async def test_simulate_end_to_end_over_stdin_and_websocket(tmp_path):
    async with service_process(tmp_path) as (proc, url), connect(url) as ws:
        c = Client(ws)
        hello = await c.recv()
        assert hello["type"] == "hello" and hello["wakeword_name"] == "Hey Ohana"
        assert await c.recv() == {"type": "state", "state": "idle"}

        send_line(proc, "wake what's for dinner")
        got = await c.until({"type": "state", "state": "idle"})
        assert types(got) == ["wake", "state", "state", "transcript", "state"]
        assert got[0] == {"type": "wake", "source": "wakeword"}
        assert sum(m["type"] == "level" for m in got) >= 3
        assert {"type": "transcript", "text": "what's for dinner", "final": True} in got

        await c.send(type="speak", text="Tacos, at six.", id="q1")
        got = await c.until({"type": "spoken"})
        assert got == [{"type": "state", "state": "speaking"}, {"type": "spoken", "id": "q1"}]

        send_line(proc, "quit")
        assert await asyncio.to_thread(proc.wait, 10) == 0


async def test_browser_origins_are_refused_by_the_real_service(tmp_path):
    async with service_process(tmp_path) as (proc, url):
        with pytest.raises(InvalidStatus):
            async with connect(url, origin="http://evil.example"):
                pass
        async with connect(url) as ws:  # the display sends no Origin
            assert json.loads(await ws.recv())["type"] == "hello"


async def test_sigterm_shuts_down_cleanly(tmp_path):
    async with service_process(tmp_path) as (proc, url), connect(url) as ws:
        await ws.recv()
        proc.send_signal(signal.SIGTERM)
        assert await asyncio.to_thread(proc.wait, 10) == 0


async def test_keeps_serving_after_stdin_closes(tmp_path):
    async with service_process(tmp_path) as (proc, url):
        assert proc.stdin is not None
        proc.stdin.close()
        await asyncio.sleep(0.3)
        assert proc.poll() is None
        async with connect(url) as ws:
            assert json.loads(await ws.recv())["type"] == "hello"
            await ws.send(json.dumps({"type": "listen"}))
            c = Client(ws)
            got = await c.until({"type": "transcript"})
            assert got[-1]["text"] == "What's for dinner tonight?"
        proc.send_signal(signal.SIGINT)
        assert await asyncio.to_thread(proc.wait, 10) == 0


def test_version_and_help():
    out = subprocess.run([sys.executable, "-m", "homeos_voice", "--version"],
                         capture_output=True, text=True, check=True).stdout
    assert out.startswith("homeos-voice ")
    out = subprocess.run([sys.executable, "-m", "homeos_voice", "--help"],
                         capture_output=True, text=True, check=True).stdout
    for flag in ("--config", "--simulate", "--host", "--port", "--log-level"):
        assert flag in out

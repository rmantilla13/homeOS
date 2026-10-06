"""The WebSocket protocol, end to end over a real socket, in simulate mode."""

from __future__ import annotations

import asyncio
import json
import time

from helpers import client, fast_sim, running, types

from homeos_voice import protocol
from homeos_voice.service import StateStore

IDLE = {"type": "state", "state": "idle"}
SPEAKING = {"type": "state", "state": "speaking"}


async def test_hello_then_state_on_connect():
    async with running() as (_, _, url), client(url, greeted=False) as c:
        hello = await c.recv()
        assert hello == {
            "type": "hello",
            "version": "1",
            "wakeword": True,
            "wakeword_name": "Hey Jarvis",
            "tts": True,
            "stt": True,
        }
        assert await c.recv() == IDLE


async def test_listen_runs_a_session_and_sends_the_transcript():
    async with running(fast_sim(listen_text="what's on today")) as (_, _, url), client(url) as c:
        await c.send(type="listen")
        got = await c.until({"type": "transcript"})
        assert types(got) == ["wake", "state", "state", "transcript"]
        assert got[0] == {"type": "wake", "source": "button"}
        assert [m["state"] for m in got if m["type"] == "state"] == ["listening", "transcribing"]
        assert got[-1] == {"type": "transcript", "text": "what's on today", "final": True}
        levels = [m for m in got if m["type"] == "level"]
        assert len(levels) >= 3
        assert all(0.0 <= m["rms"] <= 1.0 for m in levels)
        # Levels come only while listening: between "listening" and "transcribing".
        listening = got.index({"type": "state", "state": "listening"})
        transcribing = got.index({"type": "state", "state": "transcribing"})
        assert all(listening < got.index(m) < transcribing for m in levels)
        assert await c.recv() == IDLE


async def test_wake_command_uses_its_words():
    async with running() as (_, backend, url), client(url) as c:
        backend.command("wake what's for dinner")
        got = await c.until(IDLE)
        assert got[0] == {"type": "wake", "source": "wakeword"}
        assert {"type": "transcript", "text": "what's for dinner", "final": True} in got
        assert types(got) == ["wake", "state", "state", "transcript", "state"]


async def test_button_and_silence_give_an_empty_transcript():
    async with running() as (_, backend, url), client(url) as c:
        for command, source in (("button", "button"), ("silence", "wakeword")):
            backend.command(command)
            got = await c.until(IDLE)
            assert got[0] == {"type": "wake", "source": source}
            assert {"type": "transcript", "text": "", "final": True} in got


async def test_next_sets_what_listen_hears():
    async with running() as (_, backend, url), client(url) as c:
        backend.command("next turn off the lights")
        await c.send(type="listen")
        got = await c.until({"type": "transcript"})
        assert got[-1]["text"] == "turn off the lights"


async def test_speak_answers_with_spoken_after_the_words_are_said():
    backend = fast_sim(word_time=0.05)
    async with running(backend) as (_, _, url), client(url) as c:
        started = time.monotonic()
        await c.send(type="speak", text="Tacos tonight, and Leo is on dishes.", id="r1")
        got = await c.until(IDLE)
        assert got == [SPEAKING, {"type": "spoken", "id": "r1"}, IDLE]
        assert time.monotonic() - started >= 7 * 0.05 * 0.9
        assert backend.spoken == ["Tacos tonight, and Leo is on dishes."]


async def test_speak_without_an_id_gets_one():
    async with running() as (_, _, url), client(url) as c:
        await c.send(type="speak", text="Hello there")
        got = await c.until({"type": "spoken"})
        assert isinstance(got[-1]["id"], str) and got[-1]["id"]


async def test_empty_speech_is_spoken_at_once_without_a_state_change():
    async with running() as (_, _, url), client(url) as c:
        await c.send(type="speak", text="   ", id="blank")
        assert await c.recv() == {"type": "spoken", "id": "blank"}
        assert await c.quiet() == []


async def test_speech_is_queued_in_order():
    async with running() as (_, backend, url), client(url) as c:
        await c.send(type="speak", text="first one", id="1")
        await c.send(type="speak", text="second one", id="2")
        got = await c.until(IDLE)
        assert got == [SPEAKING, {"type": "spoken", "id": "1"}, {"type": "spoken", "id": "2"}, IDLE]
        assert backend.spoken == ["first one", "second one"]


async def test_stop_speaking_answers_every_pending_id():
    async with running(fast_sim(word_time=0.5)) as (_, backend, url), client(url) as c:
        await c.send(type="speak", text="a long reply that takes a while", id="a")
        await c.send(type="speak", text="and another", id="b")
        await c.until(SPEAKING)
        await c.send(type="stop_speaking")
        got = await c.until(IDLE, timeout=1.0)
        assert got == [{"type": "spoken", "id": "a"}, {"type": "spoken", "id": "b"}, IDLE]
        assert backend.spoken == ["a long reply that takes a while"]  # "b" never started
        assert await c.quiet() == []


async def test_speech_waits_until_the_session_is_over():
    async with running() as (_, _, url), client(url) as c:
        await c.send(type="listen")
        await c.until({"type": "state", "state": "listening"})
        await c.send(type="speak", text="reply", id="r")
        got = await c.until(IDLE)
        got += await c.until(IDLE)
        assert types(got) == ["state", "transcript", "state", "state", "spoken", "state"]
        assert [m.get("state") for m in got if m["type"] == "state"] == [
            "transcribing", "idle", "speaking", "idle"]


async def test_listen_interrupts_speech():
    async with running(fast_sim(word_time=1.0)) as (_, _, url), client(url) as c:
        await c.send(type="speak", text="this would take a long time", id="long")
        await c.until(SPEAKING)
        await c.send(type="listen")
        got = await c.until({"type": "state", "state": "listening"}, timeout=1.0)
        assert got == [
            {"type": "spoken", "id": "long"},
            {"type": "wake", "source": "button"},
            {"type": "state", "state": "listening"},
        ]


async def test_cancel_drops_the_session_without_a_transcript():
    async with running() as (_, _, url), client(url) as c:
        await c.send(type="listen")
        await c.until({"type": "level"})
        await c.send(type="cancel")
        got = await c.until(IDLE, timeout=1.0)
        assert "transcript" not in types(got)
        later = await c.quiet(0.8)
        assert "transcript" not in types(later)
        # And a new session works afterwards.
        await c.send(type="listen")
        got = await c.until({"type": "transcript"})
        assert got[0] == {"type": "wake", "source": "button"}


async def test_cancel_also_stops_speech():
    async with running(fast_sim(word_time=1.0)) as (_, _, url), client(url) as c:
        await c.send(type="speak", text="long reply here", id="x")
        await c.until(SPEAKING)
        await c.send(type="cancel")
        assert await c.until(IDLE, timeout=1.0) == [{"type": "spoken", "id": "x"}, IDLE]


async def test_listen_while_listening_is_ignored():
    async with running() as (_, _, url), client(url) as c:
        await c.send(type="listen")
        await c.send(type="listen")
        got = await c.until(IDLE)
        assert types(got).count("wake") == 1
        assert types(got).count("transcript") == 1


async def test_set_wakeword_broadcasts_a_fresh_hello_to_every_client():
    async with running() as (service, backend, url), client(url) as a, client(url) as b:
        await a.send(type="set", wakeword_enabled=False)
        for c in (a, b):
            hello = await c.recv()
            assert hello["type"] == "hello" and hello["wakeword"] is False
        assert service.gate.enabled is False
        # The wake word is now ignored; push-to-talk still works.
        backend.command("wake hello")
        assert await a.quiet() == []
        await a.send(type="set", wakeword_enabled=True)
        assert (await a.recv())["wakeword"] is True
        backend.command("wake hello")
        assert (await a.until({"type": "wake"}))[-1]["source"] == "wakeword"


async def test_wakeword_is_ignored_while_speaking():
    async with running(fast_sim(word_time=0.3), resume_delay=0.2) as (_, backend, url), \
            client(url) as c:
        await c.send(type="speak", text="one two three", id="s")
        await c.until(SPEAKING)
        backend.command("wake can you hear yourself")
        got = await c.until(IDLE)
        assert "wake" not in types(got)
        # Still within resume_delay of speaking: ignored.
        backend.command("wake too soon")
        assert await c.quiet(0.1) == []
        await asyncio.sleep(0.2)
        backend.command("wake now it counts")
        got = await c.until({"type": "transcript"})
        assert got[0] == {"type": "wake", "source": "wakeword"}
        assert got[-1]["text"] == "now it counts"


async def test_wakeword_is_ignored_mid_session_and_during_refractory():
    async with running(refractory=1.0) as (_, backend, url), client(url) as c:
        await c.send(type="listen")
        await c.until({"type": "state", "state": "listening"})
        backend.command("wake interrupting")
        got = await c.until(IDLE)
        assert types(got).count("wake") == 0
        assert got[-2]["text"] == "What's for dinner tonight?"
        # A real detection starts the refractory period...
        backend.command("wake first")
        await c.until(IDLE)
        backend.command("wake second")
        assert await c.quiet(0.2) == []


async def test_every_client_gets_broadcasts():
    async with running() as (_, backend, url), client(url) as a, client(url) as b:
        backend.command("wake hi")
        got_a = await a.until(IDLE)
        got_b = await b.until(IDLE)
        assert got_a == got_b
        assert got_a[0] == {"type": "wake", "source": "wakeword"}


async def test_bad_messages_get_an_error_only_for_the_sender():
    bad = [
        "not json",
        json.dumps([1, 2]),
        json.dumps({"type": "dance"}),
        json.dumps({"type": "speak"}),
        json.dumps({"type": "speak", "text": "hi", "id": ["x"]}),
        json.dumps({"type": "set", "wakeword_enabled": "yes"}),
        b"\x00\x01",
    ]
    async with running() as (_, _, url), client(url) as a, client(url) as b:
        for frame in bad:
            await a.ws.send(frame)
            msg = await a.recv()
            assert msg["type"] == "error" and msg["message"], frame
        assert await b.quiet() == []
        # The connection is still usable.
        await a.send(type="speak", text="still here", id="ok")
        assert (await a.until({"type": "spoken"}))[-1]["id"] == "ok"


async def test_without_stt_listen_is_refused():
    backend = fast_sim()
    backend.stt_available = False
    async with running(backend) as (_, _, url), client(url, greeted=False) as c:
        assert (await c.recv())["stt"] is False
        await c.recv()
        await c.send(type="listen")
        msg = await c.recv()
        assert msg["type"] == "error" and "Listening" in msg["message"]
        assert await c.quiet() == []


async def test_without_tts_speak_errors_and_still_answers_spoken():
    backend = fast_sim()
    backend.tts_available = False
    async with running(backend) as (_, _, url), client(url) as c:
        await c.send(type="speak", text="hello", id="n")
        msg = await c.recv()
        assert msg["type"] == "error"
        assert await c.recv() == {"type": "spoken", "id": "n"}
        assert await c.quiet() == []


async def test_levels_are_throttled_to_15_per_second():
    backend = fast_sim(levels=[0.5] * 60, level_step=0.005)
    async with running(backend) as (_, _, url), client(url) as c:
        await c.send(type="listen")
        got = await c.until({"type": "transcript"})
        levels = [m for m in got if m["type"] == "level"]
        # 60 levels over ~0.3 s would be ~200/s; throttled, about 15/s.
        assert 1 <= len(levels) <= 8


async def test_wakeword_setting_survives_a_restart(tmp_path):
    store = StateStore(tmp_path / "state.json")
    async with running(store=store) as (_, _, url), client(url) as c:
        await c.send(type="set", wakeword_enabled=False)
        await c.until({"type": "hello"})
    assert json.loads((tmp_path / "state.json").read_text()) == {"wakeword_enabled": False}
    async with running(store=StateStore(tmp_path / "state.json")) as (_, _, url), \
            client(url, greeted=False) as c:
        assert (await c.recv())["wakeword"] is False


async def test_state_reflects_reality_for_late_joiners():
    async with running(fast_sim(word_time=0.5)) as (_, _, url), client(url) as a:
        await a.send(type="speak", text="hello there", id="h")
        await a.until(SPEAKING)
        async with client(url, greeted=False) as late:
            assert (await late.recv())["type"] == "hello"
            assert await late.recv() == SPEAKING


def test_message_builders_match_the_spec():
    assert protocol.level(1.7) == {"type": "level", "rms": 1.0}
    assert protocol.level(-1) == {"type": "level", "rms": 0.0}
    assert protocol.transcript("hi") == {"type": "transcript", "text": "hi", "final": True}
    assert protocol.spoken("7") == {"type": "spoken", "id": "7"}
    assert protocol.error("x") == {"type": "error", "message": "x"}
    assert protocol.parse_client_message('{"type":"speak","text":"a","id":5}')["id"] == "5"
    assert protocol.parse_client_message('{"type":"cancel","extra":1}') == {"type": "cancel"}

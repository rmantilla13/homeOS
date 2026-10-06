"""The WebSocket server and the state machine behind it.

`VoiceService` owns the state (idle, listening, transcribing, speaking), the
connected clients and the wake-word gate. The audio work is done by a
backend: `pipeline.AudioBackend` on real hardware, `simulate.SimBackend` in
development and tests.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import time
import uuid
from collections import deque
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any, Protocol

from websockets.asyncio.server import Server, ServerConnection, broadcast, serve
from websockets.exceptions import ConnectionClosed

from . import protocol
from .wakeword import WakeGate

log = logging.getLogger(__name__)

# A quick answer (max_tokens 2000) fits easily; bigger frames close the connection.
MAX_MESSAGE_BYTES = 64 << 10
CLOSE_TIMEOUT_SECONDS = 2.0
# Longer replies are cut (about two minutes of speech): cleaning and
# synthesizing huge text would tie up the speech thread, which can't be stopped.
MAX_SPEAK_CHARS = 2000
# Replies waiting behind the current one; more are refused.
MAX_QUEUED_SPEECH = 16


class Backend(Protocol):
    wakeword_available: bool
    wakeword_name: str
    stt_available: bool
    tts_available: bool

    async def start(self, service: VoiceService) -> None: ...

    def begin_capture(self) -> None:
        """Called synchronously as a session starts, before `capture` runs, so
        the audio right after the wake word isn't lost."""
        ...

    async def capture(self, session: Session) -> str:
        """Record one utterance and return its text ("" if nothing was said).
        Report progress through `session`. Cancelled on `cancel`."""
        ...

    def end_capture(self) -> None:
        """Called synchronously when a session is cancelled, which may be
        before `capture` ever ran: undo `begin_capture`."""
        ...

    async def speak(self, text: str) -> None:
        """Say `text`; return when done. Cancelled on `stop_speaking`."""
        ...

    async def close(self) -> None: ...


class Session:
    """One listening turn, from the wake to the transcript."""

    def __init__(self, service: VoiceService, source: str) -> None:
        self.service = service
        self.source = source

    def level(self, rms: float) -> None:
        self.service._session_level(self, rms)

    def transcribing(self) -> None:
        self.service._session_transcribing(self)


class StateStore:
    """Remembers the wake-word switch across restarts, so turning it off on the
    display stays off after a reboot."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.path.read_text())
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as e:
            log.warning("ignoring %s: %s", self.path, e)
            return {}
        return data if isinstance(data, dict) else {}

    def save(self, data: dict[str, Any]) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data))
            os.replace(tmp, self.path)
        except OSError as e:
            log.warning("couldn't save %s: %s", self.path, e)


class VoiceService:
    def __init__(
        self,
        backend: Backend,
        *,
        wakeword_enabled: bool = True,
        refractory: float = 2.0,
        resume_delay: float = 0.5,
        level_rate: float = 15.0,
        store: StateStore | None = None,
        allowed_origins: Sequence[str] = (),
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.backend = backend
        self.store = store
        self.allowed_origins = list(allowed_origins)
        remembered = store.load().get("wakeword_enabled") if store else None
        if isinstance(remembered, bool):
            wakeword_enabled = remembered
        self.gate = WakeGate(
            enabled=wakeword_enabled,
            available=backend.wakeword_available,
            refractory=refractory,
            resume_delay=resume_delay,
            clock=clock,
        )
        self.state = "idle"
        self.clients: set[ServerConnection] = set()
        self._clock = clock
        self._level_interval = 1.0 / level_rate if level_rate > 0 else 0.0
        self._last_level = -math.inf
        self._session: Session | None = None
        self._session_task: asyncio.Task[None] | None = None
        self._speech_queue: deque[tuple[str, str]] = deque()
        self._speech_task: asyncio.Task[None] | None = None
        self._speaking_id: str | None = None
        self._tasks: set[asyncio.Task[None]] = set()

    # Clients

    async def serve(self, host: str, port: int) -> Server:
        # Any web page open in a browser on the device can reach localhost, and
        # browsers always send Origin. The display and local tools send none, so
        # a handshake with an Origin is refused (403) unless it's allowed.
        return await serve(self._client, host, port, max_size=MAX_MESSAGE_BYTES,
                           close_timeout=CLOSE_TIMEOUT_SECONDS,
                           origins=[None, *self.allowed_origins])

    async def _client(self, ws: ServerConnection) -> None:
        # Greet synchronously, then join the broadcast set: nothing can slip
        # in between, so every client sees hello, the current state, then changes.
        broadcast([ws], protocol.encode(self.hello()))
        broadcast([ws], protocol.encode(protocol.state(self.state)))
        self.clients.add(ws)
        log.info("client connected (%d connected)", len(self.clients))
        try:
            async for raw in ws:
                try:
                    msg = protocol.parse_client_message(raw)
                except protocol.ProtocolError as e:
                    self._reply(ws, protocol.error(str(e)))
                    continue
                log.debug("← %s", msg)
                self.handle(msg, ws)
        except ConnectionClosed:
            pass
        finally:
            self.clients.discard(ws)
            log.info("client disconnected (%d connected)", len(self.clients))

    def handle(self, msg: dict[str, Any], client: ServerConnection | None = None) -> None:
        kind = msg["type"]
        if kind == "listen":
            self.wake("button", client)
        elif kind == "cancel":
            self.cancel()
        elif kind == "speak":
            self.speak(msg["text"], msg.get("id"), client)
        elif kind == "stop_speaking":
            self.stop_speaking()
        elif kind == "set":
            self.set_wakeword_enabled(msg["wakeword_enabled"], client)

    def hello(self) -> dict[str, Any]:
        return protocol.hello(
            wakeword=self.gate.active,
            wakeword_name=self.backend.wakeword_name,
            tts=self.backend.tts_available,
            stt=self.backend.stt_available,
        )

    def broadcast(self, msg: dict[str, Any]) -> None:
        if msg["type"] != "level":
            log.debug("→ %s", msg)
        if self.clients:
            broadcast(self.clients, protocol.encode(msg))

    def _reply(self, client: ServerConnection | None, msg: dict[str, Any]) -> None:
        if client is None:
            self.broadcast(msg)
        else:
            broadcast([client], protocol.encode(msg))

    def capabilities_changed(self) -> None:
        """The backend gained or lost the mic or a model: tell every client."""
        self.gate.available = self.backend.wakeword_available
        self.broadcast(self.hello())

    # State

    def _set_state(self, value: str) -> None:
        if value == self.state:
            return
        self.state = value
        self.gate.set_busy(value != "idle")
        self.broadcast(protocol.state(value))

    def _spawn(self, coro: Any) -> asyncio.Task[None]:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._task_done)
        return task

    def _task_done(self, task: asyncio.Task[None]) -> None:
        self._tasks.discard(task)
        # Log a crash now; asyncio would only report it when the task is collected.
        if not task.cancelled() and task.exception() is not None:
            log.error("background task failed", exc_info=task.exception())

    # Listening

    def wake(self, source: str, client: ServerConnection | None = None) -> bool:
        """Start a listening session: from the wake word or push-to-talk
        ("button"). Returns False if it was ignored."""
        if source == "wakeword":
            blocked = self.gate.blocked_by()
            if blocked is not None:
                log.debug("wake word ignored (%s)", blocked)
                return False
        if self._session is not None:
            log.debug("already listening; %s ignored", source)
            return False
        if not self.backend.stt_available:
            self._reply(client, protocol.error(
                "Listening isn't available: no microphone or speech-to-text model "
                "(see docs/VOICE.md)"))
            return False
        # Push-to-talk interrupts a spoken reply (the wake word can't: it's
        # ignored while speaking).
        self._stop_speech(go_idle=False)
        if source == "wakeword":
            self.gate.triggered()
        session = Session(self, source)
        self._session = session
        self.backend.begin_capture()
        log.info("listening (%s)", source)
        self.broadcast(protocol.wake(source))
        self._set_state("listening")
        self._session_task = self._spawn(self._run_session(session))
        return True

    async def _run_session(self, session: Session) -> None:
        try:
            text = await self.backend.capture(session)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("listening failed: %s", e, exc_info=log.isEnabledFor(logging.DEBUG))
            self.broadcast(protocol.error(f"Listening failed: {e}"))
            text = ""
        if self._session is not session:
            return  # cancelled while the model was still busy
        self._session = None
        self._session_task = None
        self.broadcast(protocol.transcript(text))
        self._set_state("idle")
        self._kick_speech()

    def _session_level(self, session: Session, rms: float) -> None:
        if session is not self._session or self.state != "listening":
            return
        now = self._clock()
        if now - self._last_level < self._level_interval:
            return
        self._last_level = now
        self.broadcast(protocol.level(rms))

    def _session_transcribing(self, session: Session) -> None:
        if session is self._session:
            self._set_state("transcribing")

    def cancel(self) -> None:
        """Drop the current session (no transcript is sent) and any speech."""
        task, self._session_task = self._session_task, None
        if self._session is not None:
            self._session = None
            # The task may be cancelled before it starts, so its own cleanup
            # never runs.
            self.backend.end_capture()
            log.info("listening cancelled")
        if task is not None:
            task.cancel()
        self._stop_speech(go_idle=False)
        self._set_state("idle")

    # Speaking

    def speak(self, text: str, speech_id: str | None = None,
              client: ServerConnection | None = None) -> str:
        """Queue `text`; `spoken` with the same id follows when it's done or stopped."""
        if speech_id is None:
            speech_id = uuid.uuid4().hex[:12]
        if not text.strip():
            self.broadcast(protocol.spoken(speech_id))
            return speech_id
        if not self.backend.tts_available:
            self._reply(client, protocol.error(
                "Spoken replies aren't available: install piper or espeak-ng (see docs/VOICE.md)"))
            self.broadcast(protocol.spoken(speech_id))
            return speech_id
        if len(self._speech_queue) >= MAX_QUEUED_SPEECH:
            self._reply(client, protocol.error("Too many replies waiting to be spoken"))
            self.broadcast(protocol.spoken(speech_id))
            return speech_id
        if len(text) > MAX_SPEAK_CHARS:
            log.warning("reply is %d characters; speaking the first %d", len(text), MAX_SPEAK_CHARS)
            head = text[: MAX_SPEAK_CHARS + 1]
            # Cut at the last word break that fits (a hard cut if there's none).
            cut = max(head.rfind(" "), head.rfind("\n"))
            text = head[:cut].rstrip() if cut > 0 else head[:MAX_SPEAK_CHARS]
        self._speech_queue.append((speech_id, text))
        self._kick_speech()
        return speech_id

    def _kick_speech(self) -> None:
        # Replies wait while someone is talking to us, then play in order.
        if self._speech_task is None and self._session is None and self._speech_queue:
            self._speech_task = self._spawn(self._run_speech())

    async def _run_speech(self) -> None:
        me = asyncio.current_task()
        self._set_state("speaking")
        try:
            while self._speech_queue:
                speech_id, text = self._speech_queue.popleft()
                self._speaking_id = speech_id
                try:
                    await self.backend.speak(text)
                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    log.warning("speaking failed: %s", e,
                                exc_info=log.isEnabledFor(logging.DEBUG))
                    self.broadcast(protocol.error(f"Couldn't speak the reply: {e}"))
                self._speaking_id = None
                self.broadcast(protocol.spoken(speech_id))
        finally:
            # A stop already cleaned up and may have started something new.
            if self._speech_task is me:
                self._speech_task = None
                self._speaking_id = None
                if self.state == "speaking":
                    self._set_state("idle")

    def stop_speaking(self) -> None:
        self._stop_speech(go_idle=True)

    def _stop_speech(self, *, go_idle: bool) -> None:
        ids = [self._speaking_id] if self._speaking_id else []
        ids += [speech_id for speech_id, _ in self._speech_queue]
        self._speech_queue.clear()
        task, self._speech_task = self._speech_task, None
        self._speaking_id = None
        if task is not None:
            task.cancel()
            log.info("speech stopped")
        for speech_id in ids:
            self.broadcast(protocol.spoken(speech_id))
        if go_idle and self.state == "speaking":
            self._set_state("idle")

    # Settings

    def set_wakeword_enabled(self, enabled: bool, client: ServerConnection | None = None) -> None:
        self.gate.enabled = enabled
        if self.store is not None:
            self.store.save({"wakeword_enabled": enabled})
        log.info("wake word turned %s", "on" if enabled else "off")
        if enabled and not self.gate.available:
            self._reply(client, protocol.error(
                "The wake word isn't available: no microphone or wake word model "
                "(see docs/VOICE.md)"))
        # Every client learns the new setting from a fresh hello.
        self.broadcast(self.hello())

    async def close(self) -> None:
        self.cancel()
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

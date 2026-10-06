"""python -m homeos_voice [--config PATH] [--simulate] [--host] [--port] [--log-level]"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import sys

from . import __version__
from .config import DEFAULT_PATH, LOG_LEVELS, Config, ConfigError, load_config, validate
from .service import StateStore, VoiceService
from .wakeword import display_name

log = logging.getLogger("homeos_voice")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m homeos_voice",
        description="homeOS voice service: wake word, speech to text and spoken replies "
                    "for the display, over a local WebSocket.",
    )
    p.add_argument("--config", metavar="PATH",
                   help=f"TOML settings (default: {DEFAULT_PATH}, if it exists)")
    p.add_argument("--simulate", action="store_true",
                   help="no audio hardware or models; drive it with commands on stdin")
    p.add_argument("--host", help="address to listen on (default 127.0.0.1)")
    p.add_argument("--port", type=int, help="port to listen on (default 8765; 0 picks a free one)")
    p.add_argument("--log-level", choices=LOG_LEVELS)
    p.add_argument("--list-devices", action="store_true",
                   help="list audio devices and exit")
    p.add_argument("--say", metavar="TEXT",
                   help="speak TEXT with the configured voice and output, then exit")
    p.add_argument("--download-models", action="store_true",
                   help="fetch the configured voice, speech-to-text and wake word models, "
                        "then exit")
    p.add_argument("--version", action="version", version=f"homeos-voice {__version__}")
    return p


def setup_logging(level: str) -> None:
    # journald stamps each line itself.
    fmt = "%(levelname)s %(name)s: %(message)s"
    if "JOURNAL_STREAM" not in os.environ:
        fmt = "%(asctime)s " + fmt
    logging.basicConfig(level=level.upper(), format=fmt, stream=sys.stderr)
    if level != "debug":
        logging.getLogger("websockets").setLevel(logging.WARNING)


async def run(cfg: Config, *, simulate: bool = False) -> None:
    loop = asyncio.get_running_loop()
    if simulate:
        from .simulate import SimBackend, read_lines

        backend = SimBackend(display_name(cfg.wakeword.model, cfg.wakeword.name))
        store = None
    else:
        from .pipeline import AudioBackend

        backend = AudioBackend(cfg)
        log.info("loading models from %s", cfg.data_path)
        await backend.load()
        store = StateStore(cfg.data_path / "state.json")

    service = VoiceService(
        backend,
        wakeword_enabled=cfg.wakeword.enabled,
        refractory=cfg.wakeword.refractory,
        resume_delay=cfg.wakeword.resume_delay,
        store=store,
    )
    server = await service.serve(cfg.server.host, cfg.server.port)
    port = server.sockets[0].getsockname()[1]
    log.info("listening on ws://%s:%d", cfg.server.host, port)
    await backend.start(service)

    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    if simulate:
        def on_line(line: str | None) -> None:
            if line is None:
                log.info("stdin closed; still serving (Ctrl+C to stop)")
            elif not backend.command(line):
                stop.set()

        read_lines(loop, on_line)

    try:
        await stop.wait()
    finally:
        log.info("shutting down")
        server.close()
        await service.close()
        await server.wait_closed()
        await backend.close()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        cfg = load_config(args.config)
        if args.host:
            cfg.server.host = args.host
        if args.port is not None:
            cfg.server.port = args.port
        if args.log_level:
            cfg.log_level = args.log_level
        validate(cfg)
    except ConfigError as e:
        print(f"homeos-voice: {e}", file=sys.stderr)
        return 2

    setup_logging(cfg.log_level)
    for warning in cfg.warnings:
        log.warning("config: %s", warning)

    if args.list_devices:
        from .audio import AudioError, describe_devices

        try:
            print(describe_devices())
        except AudioError as e:
            print(e, file=sys.stderr)
            return 1
        return 0
    if args.say is not None:
        from .pipeline import say

        return say(cfg, args.say)
    if args.download_models:
        from .pipeline import download_models

        return download_models(cfg)

    try:
        asyncio.run(run(cfg, simulate=args.simulate))
    except KeyboardInterrupt:  # Ctrl+C while models were still loading
        return 130
    except OSError as e:  # most likely the port is taken
        log.error("%s", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

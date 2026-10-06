# homeos-voice

The Ohana voice service. It runs on the Pi next to the display, listens for
the wake word on a USB mic, transcribes what you say on the device, and speaks
the assistant's replies. The display talks to it over a local WebSocket
(`ws://127.0.0.1:8765`).

Hardware, privacy, tuning, wake-word training and troubleshooting are in
[docs/VOICE.md](../docs/VOICE.md); the protocol is section 4 of
[docs/PLATFORM_SPEC.md](../docs/PLATFORM_SPEC.md).

```bash
pip install -e 'voice[dev]'                 # core + tests: needs only websockets
pytest voice
python -m homeos_voice --simulate           # no mic or models; type `wake what's for dinner`
./voice/deploy/install-voice.sh             # on the Pi: everything, as a systemd service
```

| Module | Job |
|---|---|
| `service.py` | WebSocket server, session state machine, wake-word suppression |
| `protocol.py` | Message shapes and client message checks |
| `pipeline.py` | Real backend: mic → wake word → end of speech → Whisper; TTS → speaker |
| `simulate.py` | Simulate backend, driven by stdin |
| `audio.py`, `vad.py`, `wakeword.py`, `stt.py`, `tts.py` | sounddevice/aplay, webrtcvad + energy, openWakeWord, faster-whisper, Piper + espeak-ng |
| `config.py` | TOML settings (`voice.example.toml` documents every key) |

# Voice

Say the wake word, ask a question, and the display answers out loud. The
voice service (`voice/`, the Python package `homeos_voice`) runs on the Pi
next to the display. It listens for the wake word, records what you say,
turns it into text, and speaks the reply. The display does everything else:
it shows the quick-answer card, sends the text to the assistant, and asks the
service to speak the answer.

```
 USB mic ──▶ wake word ──▶ end of speech ──▶ Whisper ──┐ transcript   ┌──────────────┐  text  ┌───────────┐
            (openWakeWord)   (webrtcvad)     (on CPU)  ├─────────────▶│   display    │───────▶│ assistant │
                                                       │  WebSocket   │ (VoiceClient)│◀───────│ (Claude)  │
 speakers ◀── aplay ◀── Piper / espeak-ng ◀────────────┘◀─────────────│              │ reply  └───────────┘
                                                          speak       └──────────────┘
```

Audio never leaves the device. Only the transcribed text does, and the
display is what sends it, to the `assistant` function in `quick` mode.

## Hardware

**A USB microphone is required.** The JUNEBOX 10.1" panel has speakers (its
audio arrives over HDMI) but no microphone, and the Pi 5 has no audio input
of its own.

Any USB microphone that works without a driver (a "USB Audio Class" device,
which is nearly all of them) works: if `arecord -l` lists it, the service can
use it. It records whatever rate and channel count the mic offers and
converts.

| Mic | Notes |
|---|---|
| A USB conference or "boundary" mic | The simplest choice: omnidirectional, picks people up across a kitchen. Prefer a mic-only one: a speakerphone also shows up as a speaker, and PipeWire may play replies on it instead of the panel |
| ReSpeaker USB Mic Array (XMOS) | Better in a noisy room. If it only records multi-channel, set `audio.input_channel` |
| A cheap USB lavalier or dongle mic | Works within a couple of metres; raise its gain in `alsamixer` |

- Put the mic where people face the screen, away from the panel's speakers
  and from fans, dishwashers and range hoods.
- Plug it in before or after starting; the service looks for a mic every 10
  seconds. With no setting it picks the first USB microphone.
- Replies play through the panel's speakers. With the display user's
  PipeWire session up (the display installer starts it at boot), that is the
  same output the gear menu calls **Screen speakers**: off stays silent, and
  **Volume** is how loud a reply is. The service does not open HDMI on its
  own in that case, so a reply cannot keep the panel hissing. Without
  PipeWire it falls back to ALSA card `vc4hdmi0` (HDMI0, next to USB-C
  power), even if a USB mic took card 0 at boot. To play anywhere else
  (HDMI1, a USB speaker), set `audio.output_device`.

## Install

On the Pi (64-bit Raspberry Pi OS; Lite is fine), from the repository:

```bash
./voice/deploy/install-voice.sh             # or: ./display/deploy/install-pi.sh --with-voice
```

The script:

- installs `python3-venv libportaudio2 espeak-ng alsa-utils`
- creates a virtualenv at `/opt/homeos-voice` and installs the package with
  the `audio`, `stt`, `tts` and `wake` extras. Every dependency comes as a
  prebuilt wheel for the Pi's Python (3.13 on Raspberry Pi OS Trixie), about
  180 MB, so nothing is compiled and it takes a few minutes. openWakeWord is
  installed without its `tflite-runtime` dependency, which doesn't exist for
  Python 3.12 and later; the service runs its ONNX models instead.
- writes `/etc/homeos/voice.toml` from `voice/voice.example.toml` (kept on
  re-runs)
- downloads the models once (about 220 MB) into `~/.local/share/homeos-voice`:
  the Piper voice and the Whisper model from Hugging Face
  ([rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices),
  [Systran/faster-whisper-base.en](https://huggingface.co/Systran/faster-whisper-base.en)),
  and the wake-word model from openWakeWord's
  [GitHub release v0.5.1](https://github.com/dscripka/openWakeWord/releases/tag/v0.5.1)
- installs and starts the `homeos-voice` service, as the same user as the
  display, and enables it for every boot. It waits a few seconds at startup
  for that user's PipeWire socket, then listens whether or not a microphone
  is plugged in yet

Re-run it to update. Add `--skip-models` to install without downloading
models; fetch them later with
`/opt/homeos-voice/bin/python -m homeos_voice --download-models`.

### Check the mic and the speakers

Once, after installing. Stop the service so the tests can open the devices:

```bash
sudo systemctl stop homeos-voice
arecord -l                       # the USB mic is a "card N: ... USB Audio" line
arecord -D plughw:N,0 -f S16_LE -r 16000 -c 1 -d 5 /tmp/t.wav   # N from arecord -l; talk for 5 s
aplay -D default:CARD=vc4hdmi0 /tmp/t.wav                     # plays it on the panel
/opt/homeos-voice/bin/python -m homeos_voice --say "Hello from Ohana"
sudo systemctl start homeos-voice
```

Play the panel through `default:CARD=vc4hdmi0` (or `plughw:CARD=vc4hdmi0`),
never `hw:`: the Pi's HDMI audio only takes IEC958 frames, which the `default`
and `plughw` devices convert to. `--say` speaks through exactly what the
service uses, so if it's heard, replies will be too.

| Task | Command |
|---|---|
| Watch logs | `journalctl -u homeos-voice -f` |
| Restart | `sudo systemctl restart homeos-voice` |
| Change settings | `sudo nano /etc/homeos/voice.toml`, then restart |
| Test the voice | `/opt/homeos-voice/bin/python -m homeos_voice --say "Hello from Ohana"` |
| List audio devices | `/opt/homeos-voice/bin/python -m homeos_voice --list-devices` |

The display finds the service at `ws://127.0.0.1:8765` (override with
`HOMEOS_VOICE_URL` in `/etc/homeos/display.env`) and reconnects every 5
seconds, so the two can start in any order.

## Privacy

- **Nothing is recorded or stored.** Audio exists only in memory: a rolling
  window of the last few seconds for the wake-word model (openWakeWord keeps
  up to 10 s), and one question while it's transcribed, which is dropped
  right after. No audio is written to disk.
- **No audio leaves the Pi.** Wake word, speech to text and text to speech
  all run on the Pi's CPU. The transcribed text goes to the display, which
  sends it to the assistant, like a typed question.
- **The service makes no network requests.** Models are downloaded only by
  `--download-models` (run by the install script); the systemd unit sets
  `HF_HUB_OFFLINE=1` so nothing is fetched while it runs, and its
  `IPAddressDeny=any` / `IPAddressAllow=localhost` firewall holds it to the
  display's localhost socket. The unit also sandboxes it (read-only system
  directories, no new privileges).
- **Turning the wake word off sticks.** The switch in the display's settings
  sheet is saved in `~/.local/share/homeos-voice/state.json` and survives
  restarts. With it off, the mic is opened but nothing is analysed until
  someone taps the mic button.
- **Logs don't contain what was said** at the default `info` level, only
  timings. `debug` logs include transcripts; don't leave it on.
- The WebSocket listens on localhost only and has no authentication. Don't
  set `server.host` to `0.0.0.0` on a shared network.
- **Web pages can't use it.** A site open in a browser on the Pi could
  otherwise reach `ws://127.0.0.1:8765`, switch the mic on and read what was
  said. Browsers always send an `Origin` header and the display doesn't, so
  any connection with one is refused (HTTP 403) unless it's listed in
  `server.allowed_origins` (empty by default).
- For a hard guarantee, unplug the USB mic, or use one with a mute switch.

## How a question flows

1. The wake word is heard (or someone taps the mic button: push-to-talk).
   The service sends `wake` and switches to `listening`.
2. While listening it sends the mic `level` up to 15 times a second; the
   display's orb pulses with it.
3. The question ends after 0.7 s of silence, 8 s of speech at most, or 4 s
   with nobody speaking at all. Then `transcribing`, then the `transcript`.
   An empty transcript means nothing was heard.
4. The display asks the assistant and sends `speak` with the reply. The
   service speaks it and answers `spoken`.

The wake word is ignored while the service is speaking (so it can't wake
itself), while a question is in progress, for 2 s after it fires, and for
0.5 s after speaking or listening ends, while the room's echo fades.

## Settings and tuning

Every key is optional; `voice/voice.example.toml` lists them all with their
defaults. The ones you're most likely to touch:

| Setting | Default | When to change it |
|---|---|---|
| `wakeword.threshold` | `0.5` | Raise (0.6–0.7) if it wakes on TV chatter; lower (0.3–0.4) if it misses you |
| `wakeword.model` / `name` | `hey_jarvis` | After training "Hey Ohana" (below) |
| `vad.silence` | `0.7` s | Raise to 1.0 if it cuts people off mid-sentence |
| `vad.aggressiveness` | `2` | 3 in a noisy kitchen (stricter about what counts as speech) |
| `vad.no_speech` | `4.0` s | How long it waits for you to start after the wake word |
| `stt.model` | `base.en` | `tiny.en` is faster but sloppier; `small.en` is more accurate but noticeably slower on a Pi |
| `stt.initial_prompt` | empty | Family names and odd words, e.g. `"Leo, Maya, Abuela, Ohana."` |
| `tts.voice` | `en_US-amy-medium` | Any [Piper voice](https://rhasspy.github.io/piper-samples/), then `--download-models` |
| `tts.speed` | `1.0` | `1.1`–`1.2` for snappier answers |
| `audio.input_device` / `output_device` | auto | When it picks the wrong mic or speaker |

**Tuning the wake word.** Run with `log_level = "debug"` for a while and
watch `journalctl -u homeos-voice -f`. Every near miss is logged as
`wake word score 0.31 (threshold 0.50)`. If you see real attempts scoring
0.3–0.5, lower the threshold; if false wakes score just above it, raise it.
Turn debug off again afterwards (it logs transcripts).

**Changing models.** After changing `stt.model`, `tts.voice` or
`wakeword.model`, fetch them, then restart:

```bash
/opt/homeos-voice/bin/python -m homeos_voice --download-models
sudo systemctl restart homeos-voice
```

If webrtcvad isn't installed, end-of-speech falls back to a loudness
detector (`vad.engine = "energy"`, tuned by `vad.energy_threshold`). It
works in a quiet room but treats any steady sound as speech for a moment.

## A custom "Hey Ohana" wake word

The default wake word is openWakeWord's built-in "Hey Jarvis". openWakeWord
can train new phrases from synthetic speech, with no recordings needed. Its
repository ([dscripka/openWakeWord](https://github.com/dscripka/openWakeWord),
"Training New Models" in the README) has a Google Colab notebook,
`notebooks/automatic_model_training.ipynb`, that does it in about an hour.

1. Open the notebook in Colab and pick a GPU runtime.
2. Set the target phrase. Spell it the way it's said, since the samples come
   from a text-to-speech voice: `hey ohana`. Name the model `hey_homeos`
   (that file name stays; the display shows "Hey Ohana").
3. Run the cells. They generate thousands of spoken examples with Piper
   voices, mix in noise and room echo, add near-miss phrases ("ohana",
   "hello"), train a small model, and export `hey_homeos.onnx` (and
   `.tflite`). More examples and steps give a sturdier model; the notebook's
   defaults are a fine first try.
4. Copy the `.onnx` file to the Pi and point the config at it:

   ```bash
   scp hey_homeos.onnx pi@homeos.local:.local/share/homeos-voice/wakeword/
   ```

   ```toml
   [wakeword]
   model = "hey_homeos.onnx"    # looked up in ~/.local/share/homeos-voice/wakeword
   name = "Hey Ohana"          # what the display shows
   ```

5. Restart the service and tune `threshold` as above. Test from where people
   actually stand, with the room's usual noise, and leave the TV on for an
   evening to count false wakes. If it misses some voices (children's are
   often hardest), train again with more examples.

## Protocol

JSON text frames on `ws://127.0.0.1:8765`. Section 4 of
[PLATFORM_SPEC.md](PLATFORM_SPEC.md) is the contract; these are the details
behind it.

| Server → client | When |
|---|---|
| `{"type":"hello","version":"1","wakeword":bool,"wakeword_name":str,"tts":bool,"stt":bool}` | On connect, and again to everyone after `set` or when the mic is plugged in or unplugged |
| `{"type":"state","state":"idle\|listening\|transcribing\|speaking"}` | On connect (right after `hello`) and on every change |
| `{"type":"wake","source":"wakeword\|button"}` | A session starts; always followed by `listening` |
| `{"type":"level","rms":0.0-1.0}` | While listening, at most 15/s |
| `{"type":"transcript","text":str,"final":true}` | Once per session, unless it was cancelled; `""` if nothing was heard |
| `{"type":"spoken","id":str}` | Exactly once per `speak`, when finished, stopped or skipped |
| `{"type":"error","message":str}` | Bad client message (to that client only), or a runtime problem |

| Client → server | Effect |
|---|---|
| `{"type":"listen"}` | Push-to-talk. Interrupts speech; ignored if a session is already running |
| `{"type":"cancel"}` | Ends the session without a transcript, stops speech, and goes `idle` |
| `{"type":"speak","text":str,"id":str}` | Queues speech. Waits for a session in progress to finish. `id` is optional (one is made up) and at most 200 characters. Text past 2,000 characters is cut at a word break. With 16 replies already waiting, it's refused with an `error` and an immediate `spoken` |
| `{"type":"stop_speaking"}` | Stops speech and drops anything queued; each pending id gets `spoken` |
| `{"type":"set","wakeword_enabled":bool}` | Switches the wake word; answered with a fresh `hello` to every client |

- A frame over 64 KiB closes the connection (code 1009); a handshake with
  an `Origin` header not in `server.allowed_origins` is refused with 403.
- `level` is the frame's loudness mapped from −60…0 dBFS onto 0…1, so normal
  speech reads about 0.4–0.8 and can drive the orb directly.
- `hello.wakeword` is true only when the wake word is switched on *and*
  working: the mic, the wake-word model and the Whisper model are all there.
  `stt` is false without a mic or the Whisper model; `listen` is then
  answered with an `error`. `tts` is false without Piper or espeak-ng;
  `speak` then gets an `error` and an immediate `spoken`.
- Speech is markdown- and emoji-stripped before it's spoken; list items are
  read as short sentences.

## Development

```bash
pip install -e 'voice[dev]'
pytest voice
python -m homeos_voice --simulate           # add --port 0 for any free port
```

For the real models on a development machine, `pip install -e 'voice[all,dev]'`.
On Python 3.12 and later, add openWakeWord on its own, as the install script
does: `pip install --no-deps 'openwakeword>=0.6,<0.7'`.

Simulate mode needs no audio hardware or models. It speaks the full
protocol, and you drive it by typing on stdin:

| Command | Does |
|---|---|
| `wake what's for dinner` | The wake word, then a fake session that hears "what's for dinner" |
| `button` / `silence` | A session that hears nothing (empty transcript) |
| `next turn off the lights` | What the next push-to-talk `listen` hears (default "What's for dinner tonight?") |
| `quit` | Stop |

`speak` requests are logged and answered with `spoken` after 0.05 s per
word. The simulator check for the display: run the display in demo mode,
start `python -m homeos_voice --simulate`, type `wake what's for dinner` once
the display has connected, and watch the quick-answer card. To script it,
delay the commands so the display is connected first:

```bash
(sleep 8; echo "wake what's for dinner"; cat) | python -m homeos_voice --simulate
```

Closing stdin doesn't stop the service; Ctrl+C or `quit` does.

## Troubleshooting

Stop the service first (`sudo systemctl stop homeos-voice`) so the tests below
can open the devices, and start it again afterwards.

| Symptom | Check |
|---|---|
| `no microphone found` in the log | `arecord -l` should list a USB card. If it doesn't, try another USB port or cable; `dmesg -w` shows it being plugged in |
| It hears nothing / the orb barely moves | Record 5 s and play it back: `arecord -D plughw:2,0 -f S16_LE -r 16000 -c 1 -d 5 /tmp/t.wav && aplay -D default:CARD=vc4hdmi0 /tmp/t.wav` (use the card number from `arecord -l`). If it's quiet, raise the capture gain: `alsamixer -c 2`, F4 |
| It picks the wrong mic | `/opt/homeos-voice/bin/python -m homeos_voice --list-devices`, then set `audio.input_device` to part of the name, e.g. `"USB"` or `"ReSpeaker"` |
| Replies are silent | In the gear menu, **Screen speakers** off means replies stay quiet on purpose. Turn them on and raise **Volume**, and check the panel's own buttons. Then try `--say` (above). `aplay -l` lists outputs; the panel is `vc4hdmi0` on HDMI0 and `vc4hdmi1` on HDMI1. Test it: `speaker-test -D default:CARD=vc4hdmi0 -c 2 -t wav -l 1`. On HDMI1, set `audio.output_device = "default:CARD=vc4hdmi1"`. `wpctl status` shows the PipeWire output the service uses (see [PI_SETUP.md](PI_SETUP.md)) |
| `aplay: ... Device or resource busy` | Something else is playing through the same card. `fuser -v /dev/snd/*` shows what; stop it or pick another output |
| Wakes by itself | Raise `wakeword.threshold`; move the mic away from the speakers and the TV |
| Never wakes | Check the log for `wake word unavailable` (model missing: run `--download-models`). Then lower the threshold, and check that the display's wake word switch is on |
| Cuts you off | Raise `vad.silence` to 1.0 |
| Waits long after you stop talking | Background noise reads as speech: try `vad.aggressiveness = 3`, or move the mic |
| Wrong words | Add names to `stt.initial_prompt`; try `stt.model = "small.en"`; speak closer to the mic |
| Robotic voice | Piper isn't loading, so it fell back to espeak-ng. The log says why; usually the voice needs `--download-models` |
| `GPU device discovery failed ... /sys/class/drm/...vendor` in the log | Harmless: onnxruntime looks for a GPU it could use, and the Pi's doesn't describe itself that way. Ignore it |
| Display says "Voice needs the Ohana voice service" | `systemctl status homeos-voice`; the service listens on `127.0.0.1:8765` |

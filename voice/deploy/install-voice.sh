#!/usr/bin/env bash
# Installs the Ohana voice service on the Pi next to the display: wake word,
# speech to text and spoken replies, all running on the device. See
# docs/VOICE.md. Needs a USB microphone (the 10.1" panel has none).
#
#   ./voice/deploy/install-voice.sh                 # or install-pi.sh --with-voice
#   ./voice/deploy/install-voice.sh --skip-models   # don't download models now
#
# Safe to re-run: it upgrades the package, keeps an existing
# /etc/homeos/voice.toml, fetches only missing models and restarts the service.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
user="$(id -un)"
venv=/opt/homeos-voice
config=/etc/homeos/voice.toml
skip_models=0
for arg in "$@"; do
    case "$arg" in
        --skip-models) skip_models=1 ;;
        *) echo "Unknown option: $arg (try --skip-models)" >&2; exit 2 ;;
    esac
done
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user (the one the display runs as); it uses sudo where needed." >&2
    exit 1
fi

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

# The speech models' runtimes (onnxruntime, CTranslate2) only come for 64-bit.
case "$(dpkg --print-architecture)" in
    arm64|amd64) ;;
    *) echo "The voice service needs a 64-bit OS (Raspberry Pi OS 64-bit)." >&2; exit 1 ;;
esac

step "Installing packages"
sudo apt-get update
# Python for the venv, PortAudio for the mic, espeak-ng as the fallback voice,
# alsa-utils for aplay (playback) and arecord (troubleshooting). Everything
# else comes as prebuilt Python wheels, so no compilers are needed.
sudo apt-get install -y python3 python3-venv libportaudio2 espeak-ng alsa-utils

step "Installing homeos-voice into $venv"
# The venv belongs to the service user, so nothing in the repo or the venv
# ends up owned by root.
sudo mkdir -p "$venv"
sudo chown "$user": "$venv"
[ -x "$venv/bin/python" ] || python3 -m venv "$venv"
"$venv/bin/pip" install --upgrade pip
# Every dependency has a prebuilt wheel for the Pi (about 180 MB in all), so
# nothing is compiled; --only-binary keeps it that way, failing in seconds
# rather than starting an hour-long build that couldn't work anyway.
"$venv/bin/pip" install --upgrade --only-binary=:all: "$repo/voice[audio,stt,tts,wake]"
# openwakeword requires tflite-runtime, which has no wheels for Python 3.12+
# (Raspberry Pi OS Trixie has 3.13). We run its ONNX models, so it goes in
# without its dependencies; the `wake` extra above brought everything else.
"$venv/bin/pip" install --only-binary=:all: --no-deps "openwakeword>=0.6,<0.7"

step "Configuring"
sudo usermod -aG audio "$user"
sudo mkdir -p /etc/homeos
if [ ! -f "$config" ]; then
    # Every setting is commented out at its default; edit to change one.
    sudo install -m 644 "$repo/voice/voice.example.toml" "$config"
    echo "Wrote $config"
else
    echo "Keeping existing $config"
fi

if [ "$skip_models" -eq 0 ]; then
    step "Fetching models (once; about 220 MB)"
    # Into ~/.local/share/homeos-voice (data_dir); the service never downloads.
    if ! "$venv/bin/python" -m homeos_voice --config "$config" --download-models; then
        echo "Some models couldn't be fetched. The service still runs without them" >&2
        echo "(see the log); retry with: $venv/bin/python -m homeos_voice --download-models" >&2
    fi
fi

step "Installing the voice service"
# PipeWire is this user's own service. Lingering starts it at boot, which is
# what spoken replies play through. The display installer does this too.
if ! sudo loginctl enable-linger "$user" 2>/dev/null; then
    sudo mkdir -p /var/lib/systemd/linger
    sudo touch "/var/lib/systemd/linger/$user"
fi
uid="$(id -u)"
sed -e "s/@USER@/$user/g" -e "s/@UID@/$uid/g" "$repo/voice/deploy/homeos-voice.service" \
    | sudo tee /etc/systemd/system/homeos-voice.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable homeos-voice
sudo systemctl restart homeos-voice

step "Done"
if ! arecord -l 2>/dev/null | grep -q '^card'; then
    echo "No microphone found. Plug in a USB mic; the service picks it up within 10 s."
fi
echo "Logs:           journalctl -u homeos-voice -f"
echo "Test a voice:   $venv/bin/python -m homeos_voice --say 'Hello from Ohana'"
echo "Settings:       sudo nano $config, then sudo systemctl restart homeos-voice"

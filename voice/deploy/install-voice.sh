#!/usr/bin/env bash
# Installs the homeOS voice service on the Pi next to the display: wake word,
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

step "Installing packages"
sudo apt-get update
# portaudio for the mic, espeak-ng as the fallback voice, alsa-utils for aplay
# (playback) and arecord (troubleshooting); the rest builds any Python package
# that has no prebuilt wheel for this Python.
sudo apt-get install -y \
    python3 python3-venv python3-dev build-essential \
    portaudio19-dev libportaudio2 espeak-ng alsa-utils

step "Installing homeos-voice into $venv"
# The venv belongs to the service user, so nothing in the repo or the venv
# ends up owned by root.
sudo mkdir -p "$venv"
sudo chown "$user": "$venv"
[ -x "$venv/bin/python" ] || python3 -m venv "$venv"
"$venv/bin/pip" install --upgrade pip wheel
"$venv/bin/pip" install --upgrade "$repo/voice[audio,stt,tts]"
# openwakeword asks for tflite-runtime on Linux, which has no wheels for newer
# Pythons (Raspberry Pi OS Trixie ships 3.13). We run its ONNX models, so fall
# back to installing it without that dependency.
if ! "$venv/bin/pip" install --upgrade "$repo/voice[wake]"; then
    echo "Installing openwakeword without tflite-runtime (ONNX models only)"
    "$venv/bin/pip" install --upgrade onnxruntime numpy scipy scikit-learn tqdm requests
    "$venv/bin/pip" install --upgrade --no-deps "openwakeword>=0.6,<0.7"
fi

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
sed "s/@USER@/$user/" "$repo/voice/deploy/homeos-voice.service" \
    | sudo tee /etc/systemd/system/homeos-voice.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable homeos-voice
sudo systemctl restart homeos-voice

step "Done"
if ! arecord -l 2>/dev/null | grep -q '^card'; then
    echo "No microphone found. Plug in a USB mic; the service picks it up within 10 s."
fi
echo "Logs:           journalctl -u homeos-voice -f"
echo "Test a voice:   $venv/bin/python -m homeos_voice --say 'Hello from homeOS'"
echo "Settings:       sudo nano $config, then sudo systemctl restart homeos-voice"

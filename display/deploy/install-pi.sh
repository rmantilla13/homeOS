#!/usr/bin/env bash
# Sets up a Raspberry Pi 5 (Raspberry Pi OS, 64-bit) as a homeOS display:
# installs dependencies, builds and installs the app, and starts it on boot.
#
#   git clone https://github.com/rmantilla13/homeOS && cd homeOS
#   ./display/deploy/install-pi.sh                # display only
#   ./display/deploy/install-pi.sh --with-voice   # plus the voice service (wake word,
#                                                 # spoken answers); or HOMEOS_VOICE=1
#
# Safe to re-run: it rebuilds, reinstalls and restarts the app, and keeps an
# existing /etc/homeos/display.env.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
user="$(id -un)"
with_voice="${HOMEOS_VOICE:-0}"
for arg in "$@"; do
    case "$arg" in
        --with-voice) with_voice=1 ;;
        *) echo "Unknown option: $arg (try --with-voice)" >&2; exit 2 ;;
    esac
done
if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user; it uses sudo where needed." >&2
    exit 1
fi

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

step "Installing packages"
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git \
    qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-websockets-dev qt6-qpa-plugins \
    libqt6websockets6 \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
    qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
    qml6-module-qtquick-shapes qml6-module-qt5compat-graphicaleffects \
    qml6-module-qtmultimedia \
    qml6-module-qtquick-virtualkeyboard qt6-virtualkeyboard-plugin qml6-module-qt-labs-folderlistmodel \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav gstreamer1.0-gl gstreamer1.0-alsa \
    fonts-inter fonts-noto-color-emoji

step "Building homeos-display"
cmake -S "$repo/display" -B "$repo/build/display" -DCMAKE_BUILD_TYPE=Release -DHOMEOS_BUILD_TESTS=OFF
cmake --build "$repo/build/display" -j"$(nproc)"
sudo cmake --install "$repo/build/display" --prefix /usr/local

step "Granting display, GPU and touch access to $user"
for group in video render input; do
    getent group "$group" >/dev/null && sudo usermod -aG "$group" "$user"
done

step "Configuring the display"
# On the Pi 5 the GPU (render-only) and the display controller are separate DRM
# devices; Qt has to open the one that drives HDMI.
card=""
for connector in /sys/class/drm/card*-HDMI-A-*; do
    [ -e "$connector" ] || continue
    card="/dev/dri/$(basename "$connector" | cut -d- -f1)"
    break
done
card="${card:-/dev/dri/card1}"
echo "Using $card for HDMI output"

sudo mkdir -p /etc/homeos
sudo tee /etc/homeos/kms.json >/dev/null <<JSON
{ "device": "$card", "hwcursor": false }
JSON

if [ ! -f /etc/homeos/display.env ]; then
    sudo tee /etc/homeos/display.env >/dev/null <<'ENV'
# homeOS display settings. Restart after editing: sudo systemctl restart homeos-display
QT_QPA_PLATFORM=eglfs
QT_QPA_EGLFS_INTEGRATION=eglfs_kms
QT_QPA_EGLFS_KMS_CONFIG=/etc/homeos/kms.json
QT_QPA_EGLFS_HIDECURSOR=1
QT_IM_MODULE=qtvirtualkeyboard
# Keyboard layout, date and time formats (Raspberry Pi OS defaults to en_GB).
LANG=en_US.UTF-8
# 1.5 suits the 10.1" 1920x1200 panel; use 1.0 for ~21" 1080p screens.
QT_SCALE_FACTOR=1.5
# Seconds without a touch before the photo frame starts.
HOMEOS_IDLE_SECONDS=120

# Uncomment to connect to your Supabase project (otherwise it runs with demo data):
#HOMEOS_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
#HOMEOS_SUPABASE_ANON_KEY=YOUR-ANON-KEY
# The on-device voice service (install with install-pi.sh --with-voice).
#HOMEOS_VOICE_URL=ws://127.0.0.1:8765
ENV
else
    echo "Keeping existing /etc/homeos/display.env"
fi

step "Installing the kiosk service"
sed "s/@USER@/$user/" "$repo/display/deploy/homeos-display.service" \
    | sudo tee /etc/systemd/system/homeos-display.service >/dev/null
# The app needs the screen to itself, so boot to the console instead of a desktop.
if [ "$(systemctl get-default)" = "graphical.target" ]; then
    echo "Switching boot target from desktop to console (the app replaces the desktop)"
    sudo systemctl set-default multi-user.target
fi
sudo systemctl daemon-reload
sudo systemctl enable homeos-display

if [ "$with_voice" = "1" ]; then
    step "Installing the voice service"
    if [ -f "$repo/voice/deploy/install-voice.sh" ]; then
        bash "$repo/voice/deploy/install-voice.sh"
    else
        echo "voice/deploy/install-voice.sh not found; skipping the voice service" >&2
    fi
fi

step "Done"
echo "Reboot to start homeOS:  sudo reboot"
echo "Logs:                    journalctl -u homeos-display -f"
if [ "$with_voice" = "1" ]; then
    echo "Voice logs:              journalctl -u homeos-voice -f"
fi

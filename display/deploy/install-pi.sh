#!/usr/bin/env bash
# Sets up a Raspberry Pi 5 (Raspberry Pi OS, 64-bit) as a homeOS display:
# installs dependencies, builds and installs the app, and starts it on boot.
#
#   git clone https://github.com/rmantilla13/homeOS && cd homeOS
#   ./display/deploy/install-pi.sh                # display only
#   ./display/deploy/install-pi.sh --with-voice   # plus the voice service (wake word,
#                                                 # spoken answers); or HOMEOS_VOICE=1
#   ./display/deploy/install-pi.sh --with-voice --skip-models
#                                                 # fetch the voice models later;
#                                                 # or HOMEOS_VOICE_SKIP_MODELS=1
#
# Safe to re-run, also after an interrupted run: it rebuilds, reinstalls and
# restarts the app (and updates the voice service if it's installed), and
# keeps an existing /etc/homeos/display.env.
set -euo pipefail

if [ "$(uname -s)" != Linux ]; then
    echo "This runs on the Raspberry Pi. Log in to it first (ssh <user>@homeos.local)." >&2
    exit 1
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
user="$(id -un)"
uid="$(id -u)"
with_voice="${HOMEOS_VOICE:-0}"
skip_models="${HOMEOS_VOICE_SKIP_MODELS:-0}"
for arg in "$@"; do
    case "$arg" in
        --with-voice) with_voice=1 ;;
        --skip-models) skip_models=1 ;;
        *) echo "Unknown option: $arg (try --with-voice or --skip-models)" >&2; exit 2 ;;
    esac
done
if [ "$uid" -eq 0 ]; then
    echo "Run this as your normal user; it uses sudo where needed." >&2
    exit 1
fi

step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

step "Installing packages"
# First finish any package install that was cut off (say, a dropped SSH
# connection); apt refuses to run until that's done.
sudo dpkg --configure -a
# Video: Qt 6.8 (Raspberry Pi OS Trixie) plays it with the FFmpeg backend that
# comes with libqt6multimedia6. Qt 6.4 (Bookworm) uses GStreamer instead.
media=()
if [ "$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)" = bookworm ]; then
    media=(gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
           gstreamer1.0-libav gstreamer1.0-gl gstreamer1.0-alsa)
fi
# Sound: Qt plays video sound through PulseAudio, which Lite doesn't run;
# PipeWire provides it. libasound2-plugins lets ALSA programs use it too.
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git \
    qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-websockets-dev qt6-qpa-plugins \
    qt6-shadertools-dev libqt6websockets6 \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-layouts \
    qml6-module-qtquick-window qml6-module-qtquick-templates qml6-module-qtqml-workerscript \
    qml6-module-qtquick-shapes qml6-module-qt5compat-graphicaleffects \
    qml6-module-qtmultimedia \
    qml6-module-qtquick-virtualkeyboard qt6-virtualkeyboard-plugin qml6-module-qt-labs-folderlistmodel \
    pipewire pipewire-pulse wireplumber libasound2-plugins alsa-utils \
    fonts-inter fonts-noto-color-emoji \
    "${media[@]}"

step "Building homeos-display"
cmake -S "$repo/display" -B "$repo/build/display" -DCMAKE_BUILD_TYPE=Release -DHOMEOS_BUILD_TESTS=OFF
cmake --build "$repo/build/display" -j"$(nproc)"
sudo cmake --install "$repo/build/display" --prefix /usr/local

step "Granting display, GPU, touch and sound access to $user"
# The app runs without a login session, so these groups are what let it open
# the screen, the GPU, the touch panel and the sound card.
for group in video render input audio; do
    getent group "$group" >/dev/null && sudo usermod -aG "$group" "$user"
done

step "Configuring the display"
# On the Pi 5 the GPU (render only) and the display controller are separate DRM
# devices, and their card numbers can swap between boots. Qt has to open the
# one that drives HDMI, so use its stable /dev/dri/by-path name.
card=""
for connector in /sys/class/drm/card*-HDMI-A-*; do
    [ -e "$connector" ] || continue
    card="/dev/dri/$(basename "$connector" | cut -d- -f1)"
    break
done
card="${card:-/dev/dri/card1}"
for link in /dev/dri/by-path/*-card; do
    if [ -e "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$card")" ]; then
        card="$link"
        break
    fi
done
echo "Using $card for HDMI output"

# HDMI1 is Qt's name for the HDMI0 port. 1920x1200 is the panel's resolution;
# a screen that doesn't offer it gets its own preferred mode instead.
sudo mkdir -p /etc/homeos
sudo tee /etc/homeos/kms.json >/dev/null <<JSON
{
  "device": "$card",
  "hwcursor": false,
  "outputs": [ { "name": "HDMI1", "mode": "1920x1200" } ]
}
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

step "Configuring the console"
# The text console sits behind the app and shows whenever it (re)starts: keep
# it from blanking the screen and hide its blinking cursor. Kernel options all
# go on the one line of cmdline.txt; each is added only if it isn't there yet.
cmdline=/boot/firmware/cmdline.txt
add_kernel_option() {
    local option="$1" words=() word
    read -ra words <"$cmdline" || true   # (fails without a final newline, but still reads)
    for word in "${words[@]}"; do
        [ "${word%%=*}" = "${option%%=*}" ] && return 0
    done
    [ -f "$cmdline.homeos-backup" ] || sudo cp "$cmdline" "$cmdline.homeos-backup"
    sudo sed -i "1s|\$| $option|" "$cmdline"
    echo "Added $option to $cmdline (takes effect after a reboot)"
}
if [ -f "$cmdline" ]; then
    add_kernel_option consoleblank=0
    add_kernel_option vt.global_cursor_default=0
else
    echo "$cmdline not found (not a Raspberry Pi?); skipping"
fi

step "Setting up sound (the panel's speakers, over HDMI)"
# PipeWire runs as $user's own service. Lingering starts it at boot, without
# anyone logging in. (Without logind, as in a container, write the flag file
# that loginctl would.)
if ! sudo loginctl enable-linger "$user" 2>/dev/null; then
    sudo mkdir -p /var/lib/systemd/linger
    sudo touch "/var/lib/systemd/linger/$user"
fi
# ALSA programs (the voice service's replies, speaker-test) play through
# PipeWire as well, so they mix with video sound instead of fighting over the
# HDMI port. While PipeWire isn't running they go straight to HDMI0.
if [ ! -f /etc/asound.conf ] || grep -q 'homeOS' /etc/asound.conf; then
    sudo tee /etc/asound.conf >/dev/null <<ALSA
# Written by homeOS install-pi.sh. Sound goes to PipeWire, or straight to the
# panel's speakers on HDMI0 (vc4hdmi0) when PipeWire isn't running. CARD is
# accepted (as in default:CARD=vc4hdmi0) and PipeWire picks the output.
pcm.!default {
    @args [ CARD ]
    @args.CARD { type string default "vc4hdmi0" }
    type pulse
    server "unix:/run/user/$uid/pulse/native"
    fallback "sysdefault:CARD=vc4hdmi0"
}
ctl.!default {
    @args [ CARD ]
    @args.CARD { type string default "vc4hdmi0" }
    type pulse
    server "unix:/run/user/$uid/pulse/native"
    fallback "hw:CARD=vc4hdmi0"
}
ALSA
else
    echo "Keeping your own /etc/asound.conf"
fi
# WirePlumber starts each output at 40% volume (-24 dB), which makes videos
# and the voice replies quiet; start the panel at full volume instead. Its
# own volume buttons still work.
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/50-homeos.conf >/dev/null <<'WP'
# Written by homeOS install-pi.sh: outputs start at full volume (WirePlumber's
# default is 40%). A volume set later with wpctl or pactl is kept instead.
wireplumber.settings = {
  device.routes.default-sink-volume = 1.0
}
WP

if [ -d /etc/NetworkManager/conf.d ]; then
    step "Turning off Wi-Fi power saving"
    # It makes the Pi's Wi-Fi lag and drop out; the display is always plugged in.
    sudo tee /etc/NetworkManager/conf.d/homeos-wifi-powersave.conf >/dev/null <<'NM'
# Written by homeOS install-pi.sh: no Wi-Fi power saving (2 = disable).
[connection]
wifi.powersave = 2
NM
fi

step "Installing the kiosk service"
sed -e "s/@USER@/$user/g" -e "s/@UID@/$uid/g" "$repo/display/deploy/homeos-display.service" \
    | sudo tee /etc/systemd/system/homeos-display.service >/dev/null
# The app needs the screen to itself, so boot to the console instead of a desktop.
if [ "$(systemctl get-default)" = "graphical.target" ]; then
    echo "Switching boot target from desktop to console (the app replaces the desktop)"
    sudo systemctl set-default multi-user.target
fi
sudo systemctl daemon-reload
if systemctl is-enabled --quiet homeos-preview 2>/dev/null; then
    echo "Preview mode is on, so the kiosk stays off (./display/deploy/preview.sh off switches back)"
else
    sudo systemctl enable homeos-display
    # When updating, restart the app that's already on screen.
    if systemctl is-active --quiet homeos-display; then
        sudo systemctl restart homeos-display
    fi
fi

# When updating, update the voice service too if it was installed before.
if [ -f /etc/systemd/system/homeos-voice.service ]; then
    with_voice=1
fi
if [ "$with_voice" = "1" ]; then
    step "Installing the voice service"
    voice_args=()
    if [ "$skip_models" = "1" ]; then
        voice_args+=(--skip-models)
    fi
    if [ -f "$repo/voice/deploy/install-voice.sh" ]; then
        bash "$repo/voice/deploy/install-voice.sh" "${voice_args[@]}"
    else
        echo "voice/deploy/install-voice.sh not found; skipping the voice service" >&2
    fi
fi

step "Done"
# Bit 0 (now) or 16 (since boot) of get_throttled: the supply couldn't keep up.
throttled="$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p' || true)"
if [[ "$throttled" =~ ^0x[0-9a-fA-F]+$ ]] && (( throttled & 0x10001 )); then
    echo "Warning: the Pi has been short of power since it started (throttled=$throttled)." >&2
    echo "Use the official 27 W USB-C supply, and power the panel from its own adapter." >&2
fi
echo "Reboot to start homeOS:  sudo reboot"
echo "Logs:                    journalctl -u homeos-display -f"
if [ "$with_voice" = "1" ]; then
    echo "Voice logs:              journalctl -u homeos-voice -f"
fi

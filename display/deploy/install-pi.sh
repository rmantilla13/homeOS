#!/usr/bin/env bash
# Sets up a Raspberry Pi 5 (Raspberry Pi OS, 64-bit) as an Ohana display:
# installs dependencies, builds and installs the app, and starts it now and
# on every boot. The service takes the console, so a reboot shows Ohana
# instead of the login prompt.
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
# keeps an existing /etc/homeos/display.env. A file at /etc/homeos/boot.mp4
# replaces the built-in boot video; the next reboot plays it. A video set in
# the admin console is downloaded in the background, once the network is up,
# to /var/lib/homeos/boot.mp4, and plays from the next boot when that
# override is absent.
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
codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
media=()
if [ "$codename" = bookworm ]; then
    media=(gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
           gstreamer1.0-libav gstreamer1.0-gl gstreamer1.0-alsa)
fi
# Sound: Qt plays video sound through PulseAudio, which Lite doesn't run;
# PipeWire provides it. libasound2-plugins lets ALSA programs use it too.
# Boot video: the ffmpeg package includes ffplay, which draws on the KMS/DRM
# screen before the app starts. ffmpeg itself is the framebuffer fallback.
# v4l-utils: v4l2-ctl shows the HEVC decoder when checking video by hand.
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
    qml6-module-qtquick-particles qml6-module-qtquick-localstorage libqt6sql6-sqlite \
    pipewire pipewire-pulse wireplumber libasound2-plugins alsa-utils \
    fonts-inter fonts-noto-color-emoji \
    ffmpeg curl v4l-utils \
    "${media[@]}"
# Only Raspberry Pi's FFmpeg build (+rpt) can use the Pi 5 HEVC decoder.
# Trixie only: Bookworm's Qt 6.4 plays video through GStreamer.
if [ "$codename" = trixie ]; then
    avc="$(dpkg-query -W -f='${Version}' libavcodec61 2>/dev/null || true)"
    case "$avc" in
        *+rpt*) ;;
        *) echo "Warning: libavcodec61 '${avc:-missing}' is not Raspberry Pi's build (+rpt); videos will decode on the CPU." >&2 ;;
    esac
fi

step "Building homeos-display"
cmake -S "$repo/display" -B "$repo/build/display" -DCMAKE_BUILD_TYPE=Release -DHOMEOS_BUILD_TESTS=OFF
cmake --build "$repo/build/display" -j"$(nproc)"
sudo cmake --install "$repo/build/display" --prefix /usr/local

step "Granting display, GPU, touch, sound and console access to $user"
# The app runs without a desktop login, so these groups are what let it open
# the screen, the GPU, the touch panel, the sound card and the console.
for group in video render input audio tty; do
    getent group "$group" >/dev/null && sudo usermod -aG "$group" "$user"
done

step "Letting this display change Wi-Fi and reboot"
# The app has no password prompt, so a root-owned helper is the only thing
# sudo will run without asking. It changes Wi-Fi and reboots, and nothing else.
sudo install -D -m 755 "$repo/display/deploy/homeos-system" /usr/local/libexec/homeos-system
sudo tee /etc/sudoers.d/homeos-system >/dev/null <<EOF
# Ohana display: Wi-Fi and reboot only.
$user ALL=(root) NOPASSWD: /usr/local/libexec/homeos-system
EOF
sudo chmod 440 /etc/sudoers.d/homeos-system
sudo visudo -cf /etc/sudoers.d/homeos-system

# kms-pick-begin
# Print the DRM card and Qt's eglfs output name for the panel.
# The kernel calls the Pi's HDMI0 port (next to USB-C) HDMI-A-1. Qt's
# eglfs_kms calls that same connector HDMI1, and HDMI-A-2 is HDMI2.
# A connected connector wins. HDMI-A-1 wins a tie, and it is the fallback
# when the panel is still off, so the app opens that port once it comes on.
homeos_pick_hdmi() {
    local sysroot="${1:-/sys/class/drm}"
    local connector base dev name qt status
    local preferred_card="" preferred_output="" fallback_card="" fallback_output=""
    local card="/dev/dri/card1" output="HDMI1"
    for connector in "$sysroot"/card*-HDMI-A-*; do
        [ -e "$connector" ] || continue
        base=$(basename "$connector")
        dev="/dev/dri/${base%%-*}"
        name="${base#*-}"
        case "$name" in
            HDMI-A-*) qt="HDMI${name#HDMI-A-}" ;;
            *) qt="HDMI1" ;;
        esac
        status=""
        if [ -f "$connector/status" ]; then
            status=$(cat "$connector/status" 2>/dev/null || true)
        fi
        if [ "$name" = "HDMI-A-1" ]; then
            fallback_card=$dev
            fallback_output=$qt
        elif [ -z "$fallback_card" ]; then
            fallback_card=$dev
            fallback_output=$qt
        fi
        if [ "$status" = "connected" ]; then
            if [ -z "$preferred_card" ] || [ "$name" = "HDMI-A-1" ]; then
                preferred_card=$dev
                preferred_output=$qt
            fi
        fi
    done
    if [ -n "$preferred_card" ]; then
        card=$preferred_card
        output=$preferred_output
    elif [ -n "$fallback_card" ]; then
        card=$fallback_card
        output=$fallback_output
    fi
    printf '%s\n%s\n' "$card" "$output"
}
# kms-pick-end

step "Configuring the display"
# On the Pi 5 the GPU (render only) and the display controller are separate DRM
# devices, and their card numbers can swap between boots. Qt has to open the
# one that drives HDMI, so use its stable /dev/dri/by-path name.
mapfile -t picked < <(homeos_pick_hdmi /sys/class/drm)
card="${picked[0]}"
output="${picked[1]}"
for link in /dev/dri/by-path/*-card; do
    if [ -e "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$card")" ]; then
        card="$link"
        break
    fi
done
echo "Using $card ($output) for HDMI output"

# 1920x1200 is the panel's resolution; a screen that doesn't offer it gets
# its own preferred mode instead.
sudo mkdir -p /etc/homeos
sudo tee /etc/homeos/kms.json >/dev/null <<JSON
{
  "device": "$card",
  "hwcursor": false,
  "outputs": [ { "name": "$output", "mode": "1920x1200" } ]
}
JSON

if [ ! -f /etc/homeos/display.env ]; then
    sudo tee /etc/homeos/display.env >/dev/null <<'ENV'
# Ohana display settings. Restart after editing: sudo systemctl restart homeos-display
QT_QPA_PLATFORM=eglfs
QT_QPA_EGLFS_INTEGRATION=eglfs_kms
QT_QPA_EGLFS_KMS_CONFIG=/etc/homeos/kms.json
QT_QPA_EGLFS_HIDECURSOR=1
QT_QPA_EGLFS_ALWAYS_SET_MODE=1
QT_IM_MODULE=qtvirtualkeyboard
# Date and time formats (Raspberry Pi OS defaults to en_GB). The on-screen
# keyboard is US English either way.
LANG=en_US.UTF-8
# 1.5 suits the 10.1" 1920x1200 panel; use 1.0 for ~21" 1080p screens.
QT_SCALE_FACTOR=1.5
# Seconds without a touch before the photo frame starts.
HOMEOS_IDLE_SECONDS=120

# Uncomment to connect to your Supabase project (otherwise it runs with demo data):
#HOMEOS_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
#HOMEOS_SUPABASE_ANON_KEY=YOUR-ANON-KEY
# Admin app that signs private photo and video URLs (Vercel Blob). Unset, it
# is https://ohanaos.co, the same as the iOS app. Set it only if your phones
# use another deployment.
#HOMEOS_MEDIA_URL=https://YOUR-ADMIN.vercel.app
# The on-device voice service (install with install-pi.sh --with-voice).
#HOMEOS_VOICE_URL=ws://127.0.0.1:8765
# Seconds the boot video waits for Wi-Fi, so Ohana opens connected (0-60).
#HOMEOS_BOOT_NETWORK_WAIT=30
# Video decoding: drm = the Pi 5 HEVC decoder, "," = CPU only. install-pi.sh
# checks the decoder and sets this; a value you write or change is kept.
#QT_FFMPEG_DECODING_HW_DEVICE_TYPES=drm
ENV
else
    echo "Keeping existing /etc/homeos/display.env"
fi
# Lines are appended below. A hand-edited file may not end in a newline, and
# the new line would then run into its last value.
end_with_newline() {
    if [ -s "$1" ] && [ -n "$(sudo tail -c 1 "$1")" ]; then
        echo | sudo tee -a "$1" >/dev/null
    fi
}
# A file left by an older install can omit the KMS lines. Qt then never opens
# HDMI and the service stays up on a text console. Fill those keys in place
# and leave scale, language and Supabase settings alone.
ensure_display_env() {
    local key="$1" value="$2" file=/etc/homeos/display.env
    if sudo grep -qE "^${key}=" "$file"; then
        sudo sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        end_with_newline "$file"
        printf '%s=%s\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
    fi
}
ensure_display_env QT_QPA_PLATFORM eglfs
ensure_display_env QT_QPA_EGLFS_INTEGRATION eglfs_kms
ensure_display_env QT_QPA_EGLFS_KMS_CONFIG /etc/homeos/kms.json
ensure_display_env QT_QPA_EGLFS_HIDECURSOR 1
ensure_display_env QT_QPA_EGLFS_ALWAYS_SET_MODE 1

step "Checking the Pi 5 HEVC decoder"
# hevc-selftest-begin
# Written above the key, with the value, when the installer chose it. Later
# installs test again and replace it. A value without this line, or changed
# since, is the owner's and is kept.
hevc_marker='# set by install-pi.sh hevc self-test'
hevc_key=QT_FFMPEG_DECODING_HW_DEVICE_TYPES

# 1 s HEVC clips (8- and 10-bit), decoded on the HEVC block and on the CPU
# through the same FFmpeg libraries Qt uses. HEVC decoding is bit-exact, so
# the frames must match. Returns 0 = works, 1 = broken, 2 = could not test.
hevc_hw_selftest() {
    local dir bits fmt sw hw rc=0
    dir="$(mktemp -d)"
    for bits in 8 10; do
        fmt=yuv420p
        if [ "$bits" = 10 ]; then
            fmt=yuv420p10le
        fi
        if ! timeout -k 5 60 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 \
                -c:v libx265 -x265-params log-level=error -pix_fmt "$fmt" "$dir/$bits.mp4" \
            || ! sw="$(timeout -k 5 60 ffmpeg -nostdin -hide_banner -loglevel error -i "$dir/$bits.mp4" -map 0:v \
                -pix_fmt "$fmt" -f framemd5 -)"; then
            rc=2
            break
        fi
        # sudo: this login may not be in the video group yet; the service is.
        # A hang (a stuck decoder) counts as broken. -k: ffmpeg waits for its
        # decoder thread after one SIGTERM, so a stuck one needs SIGKILL.
        if ! hw="$(sudo timeout -k 5 60 ffmpeg -nostdin -hide_banner -loglevel info -hwaccel drm -i "$dir/$bits.mp4" \
                -map 0:v -pix_fmt "$fmt" -f framemd5 - 2>"$dir/$bits.log")"; then
            # A format the ffmpeg tool can't convert says nothing about the decoder.
            if grep -q 'Impossible to convert' "$dir/$bits.log"; then
                rc=2
            else
                rc=1
            fi
            break
        fi
        # Frame hashes only (the last column): timestamps may differ.
        sw="$(printf '%s\n' "$sw" | awk -F', *' '!/^#/ && NF { print $NF }')"
        hw="$(printf '%s\n' "$hw" | awk -F', *' '!/^#/ && NF { print $NF }')"
        if ! grep -q 'Hwaccel V4L2 HEVC stateless' "$dir/$bits.log" || [ -z "$hw" ] || [ "$hw" != "$sw" ]; then
            rc=1
            break
        fi
    done
    rm -rf "$dir"
    return "$rc"
}

# Prints "own" when display.env sets the key without the marker above it, or
# with another value than the marker's (edited in place), "installer" when
# only the installer set it, and nothing when it's unset. systemd allows
# blanks before a key.
hevc_env_owner() {
    sudo awk -v marker="$hevc_marker" -v key="$hevc_key=" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        index(line, key) == 1 {
            if (prev == marker ": " substr(line, length(key) + 1)) mine = 1; else own = 1
        }
        { prev = $0 }
        END { if (own) print "own"; else if (mine) print "installer" }' "$1"
}

# Writes the self-test result ($2) to display.env ($1): drm when it works, ","
# when it doesn't. "Could not test" changes nothing; the app turns drm on by
# itself. A value the owner set is never touched.
hevc_record() {
    local file="$1" rc="$2" value kept
    case "$rc" in
        0) value=drm ;;
        1) value=, ;;
        *) return 0 ;;
    esac
    if [ "$(hevc_env_owner "$file")" = own ]; then
        return 0
    fi
    # Everything but the previous result (the marker and the key under it).
    # If the file can't be read, leave it alone rather than rewrite it.
    kept="$(sudo awk -v marker="$hevc_marker" -v key="$hevc_key=" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        index($0, marker) == 1 { mine = 1; next }
        mine && index(line, key) == 1 { mine = 0; next }
        { mine = 0; print }' "$file")" || return 0
    # tee rewrites the file in place, so its owner and mode stay.
    {
        if [ -n "$kept" ]; then
            printf '%s\n' "$kept"
        fi
        printf '%s: %s\n%s=%s\n' "$hevc_marker" "$value" "$hevc_key" "$value"
    } | sudo tee "$file" >/dev/null
}
# hevc-selftest-end

# Not a Pi 5 (or a container): there is no decoder to test.
if ! grep -qsiE 'hevc|rpivid' /sys/class/video4linux/video*/name; then
    echo "No HEVC decoder found (not a Pi 5?); skipping the check"
elif [ "$codename" = bookworm ]; then
    echo "Qt 6.4 plays video through GStreamer here; skipping the check"
elif [ "$(hevc_env_owner /etc/homeos/display.env)" = own ]; then
    echo "Keeping $hevc_key from display.env"
else
    hevc_rc=0
    hevc_hw_selftest || hevc_rc=$?
    case "$hevc_rc" in
        0) echo "HEVC hardware decoding works" ;;
        1) echo "HEVC hardware decoding failed its check; videos will decode on the CPU" >&2 ;;
        *) echo "Could not test HEVC hardware decoding; leaving the setting as it was" >&2 ;;
    esac
    hevc_record /etc/homeos/display.env "$hevc_rc"
fi

step "Configuring the console"
# Hide the rainbow splash and the kernel log, and keep the console from
# blanking or showing a cursor behind the app. The panel then stays dark
# until the boot video (or Ohana) draws, instead of scrolling boot text.
# SSH is unchanged. Takes effect on reboot.
"$repo/display/deploy/quiet-boot.sh"

# cloud-init prints "Completed socket interaction for boot stage final" on
# the HDMI console after quiet boot. The kernel command line does not stop
# it: those units use StandardOutput=journal+console. Send that to the
# journal, and keep cloud-init's own log off the console. A reboot applies it.
sudo mkdir -p /etc/cloud/cloud.cfg.d
sudo tee /etc/cloud/cloud.cfg.d/99-homeos-quiet.cfg >/dev/null <<'EOF'
# Written by homeOS install-pi.sh. Boot-stage text stays in the log.
output: {all: ">> /var/log/cloud-init-output.log"}
EOF
for unit in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
    if [ ! -f "/lib/systemd/system/$unit" ] && [ ! -f "/usr/lib/systemd/system/$unit" ]; then
        continue
    fi
    sudo mkdir -p "/etc/systemd/system/${unit}.d"
    sudo tee "/etc/systemd/system/${unit}.d/homeos-quiet.conf" >/dev/null <<'EOF'
# Written by homeOS install-pi.sh. Do not paint the HDMI console.
[Service]
StandardOutput=journal
StandardError=journal
EOF
done

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
# Full volume on this panel's HDMI speakers is mostly hiss. Start lower;
# the gear menu can turn them off or up. A volume set later is kept.
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/50-homeos.conf >/dev/null <<'WP'
# Written by homeOS install-pi.sh. 0.5 is loud enough for a video without
# the panel's amplifier sitting at full scale (that hiss). A volume set
# later with wpctl is kept instead.
wireplumber.settings = {
  device.routes.default-sink-volume = 0.5
}
WP
# Close the HDMI audio device soon after playback, so the speakers go quiet
# instead of holding a silent stream open.
sudo tee /etc/wireplumber/wireplumber.conf.d/51-homeos-speakers.conf >/dev/null <<'WP'
# Written by homeOS install-pi.sh.
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 1
      }
    }
  }
]
WP
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    systemctl --user try-restart wireplumber.service pipewire.service pipewire-pulse.service || true
fi

if [ -d /etc/NetworkManager/conf.d ]; then
    step "Turning off Wi-Fi power saving"
    # It makes the Pi's Wi-Fi lag and drop out; the display is always plugged in.
    sudo tee /etc/NetworkManager/conf.d/homeos-wifi-powersave.conf >/dev/null <<'NM'
# Written by homeOS install-pi.sh: no Wi-Fi power saving (2 = disable).
[connection]
wifi.powersave = 2
NM
fi

step "Keeping SSH typing responsive"
# OpenSSH sets IP_TOS to low-delay (IPTOS_LOWDELAY). Many access points
# mishandle those packets, so keystrokes stutter over Wi-Fi even when the
# Pi is idle. cs0 leaves them unmarked. UseDNS skips a reverse lookup that
# only slows login. This file is homeOS-owned and rewritten on every run.
# A reload applies it in the current session; a reboot is not required.
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/homeos.conf >/dev/null <<'EOF'
# Written by homeOS install-pi.sh.
IPQoS cs0 cs0
UseDNS no
EOF
sudo chmod 644 /etc/ssh/sshd_config.d/homeos.conf
# Debian and Raspberry Pi OS name the unit ssh.service. Reload does not
# drop the session. If ssh is not running, the drop-in applies when it starts.
if systemctl is-active --quiet ssh; then
    sudo systemctl reload ssh
fi

step "Installing the boot video"
sudo install -d -m 755 /var/lib/homeos
sudo install -D -m 755 "$repo/display/deploy/boot/homeos-bootscreen" /usr/local/libexec/homeos-bootscreen
sudo install -D -m 755 "$repo/display/deploy/boot/homeos-stop-bootscreen" /usr/local/libexec/homeos-stop-bootscreen
sudo install -D -m 644 "$repo/display/deploy/boot/boot.mp4" /usr/local/share/homeos/boot.mp4
sudo install -D -m 644 "$repo/display/deploy/homeos-bootscreen.service" /etc/systemd/system/homeos-bootscreen.service
sudo install -m 644 "$repo/display/deploy/homeos-boot-video-sync.service" /etc/systemd/system/homeos-boot-video-sync.service
sudo install -m 644 "$repo/display/deploy/homeos-boot-video-sync.timer" /etc/systemd/system/homeos-boot-video-sync.timer

step "Installing the kiosk service"
sed -e "s/@USER@/$user/g" -e "s/@UID@/$uid/g" "$repo/display/deploy/homeos-display.service" \
    | sudo tee /etc/systemd/system/homeos-display.service >/dev/null
sudo install -m 644 "$repo/display/deploy/homeos-display.pam" /etc/pam.d/homeos-display
# Linger starts the user manager at boot. Start it now too, so /run/user/$uid
# exists (XDG_RUNTIME_DIR, PipeWire) before the kiosk is launched. Config
# above is already in place, so PipeWire picks it up.
if ! sudo systemctl start "user@${uid}.service"; then
    echo "User manager did not start yet; the kiosk retries once logind brings it up." >&2
fi
# The app needs the screen to itself, so boot to the console instead of a desktop.
if [ "$(systemctl get-default)" = "graphical.target" ]; then
    echo "Switching boot target from desktop to console (the app replaces the desktop)"
    sudo systemctl set-default multi-user.target
fi
# logind starts a login on tty1 when it thinks the console is idle. The kiosk
# holds that console; a prompt must not come back between restarts. Do not
# restart logind here: that drops the SSH session this script is running in.
# The file applies on the next boot. This boot stops getty below.
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/homeos.conf >/dev/null <<'EOF'
# Written by homeOS install-pi.sh.
# The kiosk owns tty1. Do not start a login prompt when the console looks idle.
[Login]
NAutoVTs=0
ReserveVT=0
EOF
sudo systemctl daemon-reload
# The admin's boot video downloads after boot, never during it. Fetch it now
# too, in the background, so the reboot below can already play it.
if ! sudo systemctl enable --now homeos-boot-video-sync.timer; then
    echo "The boot video download timer did not start; the built-in or cached video still plays." >&2
fi
sudo systemctl start --no-block homeos-boot-video-sync.service || true
# kiosk-boot-begin
if systemctl is-enabled --quiet homeos-preview 2>/dev/null; then
    echo "Preview mode is on, so the kiosk stays off (./display/deploy/preview.sh off switches back)"
    sudo systemctl disable --now homeos-display 2>/dev/null || true
    sudo systemctl disable --now homeos-bootscreen 2>/dev/null || true
else
    # A previous install may have left this disabled or masked. enable writes
    # the multi-user.target.wants symlink, which is what a reboot starts.
    # --now starts it in this boot. restart then loads the binary this run
    # just installed (enable --now leaves an already-running process alone)
    # and also starts the unit if that first start did not stay up. Do not
    # skip this when the unit is inactive: that is a fresh install, and a
    # unit systemd dropped from the previous boot transaction.
    sudo systemctl unmask homeos-display
    sudo systemctl unmask homeos-bootscreen 2>/dev/null || true
    # Enabled for the next reboot only. Starting it now would fight the app
    # this restart is about to put on the screen. A failure here must not
    # skip enabling the kiosk.
    if ! sudo systemctl enable homeos-bootscreen; then
        echo "Boot video was not enabled. The app still starts; re-run the installer to try the video again." >&2
    fi
    # Enable before anything touches tty1. Run from a login on the panel, this
    # script is hung up with that console below, and the next boot must still
    # start the kiosk.
    if ! sudo systemctl enable homeos-display; then
        echo "homeos-display could not be enabled yet; enable --now below tries again." >&2
    fi
    # Mask the console login on tty1. Conflicts= in the unit usually wins, but
    # if the kiosk is slow or exits once before DRM is ready, getty can paint
    # a login prompt and stay there. Masking leaves SSH as the way in; the
    # PI_SETUP recovery path unmasks when you want a local prompt. A mask
    # does not stop a prompt that is already up. The kiosk start below does
    # (Conflicts=) in the same transaction, so systemd still hands tty1 over
    # if that hangs up the login this script runs in. A failure here must not
    # skip the kiosk.
    sudo systemctl mask getty@tty1.service autovt@tty1.service 2>/dev/null || true
    # An older unit may have exhausted its start limit and will refuse --now
    # until that failure is cleared.
    sudo systemctl reset-failed homeos-display || true
    if ! sudo systemctl enable --now homeos-display; then
        echo "homeos-display did not stay up on the first start. It stays enabled and will keep retrying." >&2
    fi
    if ! sudo systemctl restart homeos-display; then
        echo "homeos-display did not stay up yet. It will keep retrying, including on the next boot." >&2
    fi
fi
# kiosk-boot-end

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
if systemctl is-enabled --quiet homeos-preview 2>/dev/null; then
    echo "Preview mode is on; the panel kiosk stays off."
else
    state="$(systemctl is-active homeos-display 2>/dev/null || true)"
    echo "Ohana is enabled and started. On every boot it takes HDMI (no login prompt)."
    echo "systemctl is-active homeos-display: ${state:-unknown}"
    echo "active means the app has the panel. A terminal on the panel means it does not."
    echo "To put Ohana on HDMI:  sudo systemctl enable --now homeos-display"
    echo "Reboot so the console settings apply:  sudo reboot"
    echo "That reboot hides boot text and plays a short video until the app is up."
    if [ "$state" != "active" ]; then
        echo "The service is not active. Logs (this does not start the screen):" >&2
        echo "  journalctl -u homeos-display -b --no-pager" >&2
    fi
fi
echo "On the screen, the gear icon changes Wi-Fi, speaker volume, and can restart or reboot."
echo "Logs only (does not start the screen):  journalctl -u homeos-display -f"
if [ "$with_voice" = "1" ]; then
    echo "Voice logs:              journalctl -u homeos-voice -f"
fi

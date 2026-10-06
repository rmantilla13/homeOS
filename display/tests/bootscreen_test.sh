#!/usr/bin/env bash
# The boot video, its player, and the handoff to the kiosk. No Pi or systemd:
# ffprobe reads the file when it is installed, and a fake pid checks that the
# stop helper actually ends the player.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
video="$root/display/deploy/boot/boot.mp4"
player="$root/display/deploy/boot/homeos-bootscreen"
stop="$root/display/deploy/boot/homeos-stop-bootscreen"
unit="$root/display/deploy/homeos-bootscreen.service"
display="$root/display/deploy/homeos-display.service"
install="$root/display/deploy/install-pi.sh"

fail() { printf 'bootscreen test failed: %s\n' "$1" >&2; exit 1; }

bash -n "$player" || fail "player script has a syntax error"
bash -n "$stop" || fail "stop helper has a syntax error"
bash -n "$install" || fail "install-pi.sh has a syntax error"

[ -f "$video" ] || fail "boot.mp4 is missing"
size=$(wc -c <"$video")
[ "$size" -gt 20000 ] || fail "boot.mp4 is too small ($size)"
[ "$size" -lt 2500000 ] || fail "boot.mp4 is too large ($size)"
# MP4 files carry 'ftyp' at byte 4.
magic=$(dd if="$video" bs=1 skip=4 count=4 2>/dev/null || true)
[ "$magic" = "ftyp" ] || fail "boot.mp4 is not an mp4"

if command -v ffprobe >/dev/null 2>&1; then
    probe=$(ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -show_entries format=duration -of default=nw=1 "$video")
    printf '%s\n' "$probe" | grep -qx 'codec_name=h264' || fail "video is not h264"
    printf '%s\n' "$probe" | grep -qx 'width=1920' || fail "video is not 1920 wide"
    printf '%s\n' "$probe" | grep -qx 'height=1200' || fail "video is not 1200 tall"
    if printf '%s\n' "$probe" | grep -qx 'codec_type=audio'; then
        fail "boot video should be silent"
    fi
    dur=$(printf '%s\n' "$probe" | sed -n 's/^duration=//p' | head -1)
    awk -v d="$dur" 'BEGIN { exit !(d >= 4 && d <= 8) }' || fail "duration $dur is not a few seconds"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -v error -i "$video" -frames:v 1 -f null - || fail "ffmpeg could not decode a frame"
    fi
fi

# Comments stripped so a note mentioning Conflicts= cannot satisfy a check.
unit_body() { sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*#/d' "$1"; }

unit_body "$unit" | grep -q 'ExecStart=/usr/local/libexec/homeos-bootscreen' || fail "player unit has the wrong start"
unit_body "$unit" | grep -q 'Before=homeos-display.service' || fail "video is not ordered before the app"
unit_body "$unit" | grep -q 'Before=.*getty@tty1.service' || fail "video does not precede getty"
unit_body "$unit" | grep -q 'Conflicts=.*getty@tty1.service' || fail "video does not keep getty off tty1"
if unit_body "$unit" | grep -q 'Conflicts=.*homeos-display'; then
    fail "a conflict with the kiosk drops one of them from the boot transaction"
fi
if unit_body "$unit" | grep -Eq '^After=.*getty@'; then
    fail "After=getty lets the login prompt win"
fi

unit_body "$display" | grep -q 'ExecStartPre=-+/usr/local/libexec/homeos-stop-bootscreen' || fail "kiosk does not stop the video first"
unit_body "$display" | grep -q 'After=homeos-bootscreen.service' || fail "kiosk does not wait until the video has started"
if unit_body "$display" | grep -q 'Conflicts=.*homeos-bootscreen'; then
    fail "kiosk conflicts with the video, so one of them will not start"
fi

grep -q 'disable_splash=1' "$install" || fail "installer does not hide the rainbow splash"
grep -q 'logo.nologo' "$install" || fail "installer does not hide the kernel logo"
grep -q 'systemd.show_status=false' "$install" || fail "installer does not hide systemd status"
grep -q 'loglevel=3' "$install" || fail "installer does not set loglevel"
grep -q 'add_kernel_option quiet' "$install" || fail "installer does not set quiet"
grep -q 'plymouth.enable=0' "$install" || fail "installer does not disable plymouth"
grep -q 'ffmpeg' "$install" || fail "installer does not install ffmpeg"
grep -q '/etc/homeos/boot.mp4' "$install" || fail "installer does not document the custom video path"
grep -q 'enable homeos-bootscreen' "$install" || fail "installer does not enable the video"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'not a video' >"$tmp/custom.mp4"
printf 'not a video' >"$tmp/installed.mp4"
out=$(HOMEOS_BOOTSCREEN_DRY_RUN=1 \
    HOMEOS_BOOT_CUSTOM="$tmp/custom.mp4" \
    HOMEOS_BOOT_INSTALLED="$tmp/installed.mp4" \
    "$player")
printf '%s\n' "$out" | grep -qx "video=$tmp/custom.mp4" || fail "custom video did not win"
rm -f "$tmp/custom.mp4"
out=$(HOMEOS_BOOTSCREEN_DRY_RUN=1 \
    HOMEOS_BOOT_CUSTOM="$tmp/custom.mp4" \
    HOMEOS_BOOT_INSTALLED="$tmp/installed.mp4" \
    "$player")
printf '%s\n' "$out" | grep -qx "video=$tmp/installed.mp4" || fail "built-in video was not used"
printf '%s\n' "$out" | grep -qx 'ffplay=1' || fail "dry run did not see ffplay"
# A name with a space has to survive.
mkdir -p "$tmp/my video"
printf 'x' >"$tmp/my video/boot.mp4"
out=$(HOMEOS_BOOTSCREEN_DRY_RUN=1 HOMEOS_BOOT_VIDEO="$tmp/my video/boot.mp4" "$player")
printf '%s\n' "$out" | grep -qx "video=$tmp/my video/boot.mp4" || fail "video path with a space was split"

# The stop helper must end the player without asking systemd for a job.
sleep 30 &
pid=$!
HOMEOS_BOOTSCREEN_PID=$pid "$stop"
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "stop helper left the player running"
fi

echo "bootscreen ok"

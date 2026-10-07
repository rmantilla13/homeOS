#!/usr/bin/env bash
# The boot video, its player, and the handoff to the kiosk. No Pi or systemd:
# ffprobe reads the file when it is installed, stand-ins replace curl and
# ffplay, and the stop helper has to end the real player script.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
video="$root/display/deploy/boot/boot.mp4"
player="$root/display/deploy/boot/homeos-bootscreen"
stop="$root/display/deploy/boot/homeos-stop-bootscreen"
unit="$root/display/deploy/homeos-bootscreen.service"
sync_unit="$root/display/deploy/homeos-boot-video-sync.service"
sync_timer="$root/display/deploy/homeos-boot-video-sync.timer"
display="$root/display/deploy/homeos-display.service"
install="$root/display/deploy/install-pi.sh"
quiet="$root/display/deploy/quiet-boot.sh"

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

if unit_body "$unit" | grep -q 'network'; then
    fail "the boot video waits on the network"
fi
unit_body "$sync_unit" | grep -qx 'ExecStart=/usr/local/libexec/homeos-bootscreen --sync' || fail "download unit has the wrong start"
unit_body "$sync_unit" | grep -qx 'After=network-online.target' || fail "download runs before the network is up"
unit_body "$sync_unit" | grep -qx 'Wants=network-online.target' || fail "download does not ask for the network"
unit_body "$sync_unit" | grep -qx 'Type=oneshot' || fail "download unit is not a oneshot"
unit_body "$sync_timer" | grep -qx 'WantedBy=timers.target' || fail "download timer is not enabled with the timers"
unit_body "$sync_timer" | grep -q '^OnBootSec=' || fail "download timer does not run after boot"
unit_body "$sync_timer" | grep -q '^OnUnitActiveSec=' || fail "download timer does not check again later"
grep -q 'homeos-boot-video-sync.service' "$install" || fail "installer does not install the download unit"
grep -q 'enable --now homeos-boot-video-sync.timer' "$install" || fail "installer does not start the download timer"

unit_body "$display" | grep -q 'ExecStartPre=-+/usr/local/libexec/homeos-stop-bootscreen' || fail "kiosk does not stop the video first"
unit_body "$display" | grep -q 'After=homeos-bootscreen.service' || fail "kiosk does not wait until the video has started"
if unit_body "$display" | grep -q 'Conflicts=.*homeos-bootscreen'; then
    fail "kiosk conflicts with the video, so one of them will not start"
fi

# Quiet boot lives in quiet-boot.sh (kiosk_boot_test.sh runs it on sample
# files); the installer has to call it.
grep -Fq 'display/deploy/quiet-boot.sh' "$install" || fail "installer does not run quiet-boot.sh"
grep -q 'set_config_key disable_splash 1' "$quiet" || fail "quiet boot does not hide the rainbow splash"
for opt in quiet logo.nologo systemd.show_status=false loglevel=3 plymouth.enable=0; do
    grep -qx "    $opt" "$quiet" || fail "quiet boot does not set $opt"
done
grep -qx 'drop_options=(splash)' "$quiet" || fail "quiet boot does not drop the Plymouth splash"
grep -q 'ffmpeg curl' "$install" || fail "installer does not install ffmpeg and curl"
grep -q '/etc/homeos/boot.mp4' "$install" || fail "installer does not document the custom video path"
grep -q 'enable homeos-bootscreen' "$install" || fail "installer does not enable the video"
grep -q '99-homeos-quiet.cfg' "$install" || fail "installer does not silence cloud-init logs"
grep -q 'cloud-final.service' "$install" || fail "installer does not override cloud-final"
grep -q 'StandardOutput=journal' "$install" || fail "installer does not take cloud-init off the console"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'not a video' >"$tmp/custom.mp4"
printf 'not a video' >"$tmp/installed.mp4"
# Keep the real display env and any cache on this machine out of the test.
export HOMEOS_DISPLAY_ENV="$tmp/missing.env"
export HOMEOS_BOOT_CACHE="$tmp/cache.mp4"
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

# Remote boot video. The fetch stand-in writes a body and prints an HTTP code.
cat >"$tmp/fetch" <<'EOF'
#!/bin/bash
dest=$1
url=$2
printf '%s\n' "$url" >"${HOMEOS_FETCH_URL_FILE:?}"
case "${HOMEOS_FAKE_HTTP:-000}" in
    200)
        printf 'xxxxftypiso' >"$dest"
        printf '200'
        ;;
    200-html)
        printf '<html>captive portal</html>' >"$dest"
        printf '200'
        ;;
    304)
        printf '304'
        ;;
    404)
        printf '{"status":"404"}' >"$dest"
        printf '404'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$tmp/fetch"
printf 'HOMEOS_SUPABASE_URL="https://example.supabase.co"\n#HOMEOS_SUPABASE_ANON_KEY=ignored\nHOMEOS_SUPABASE_ANON_KEY='"'"'test-anon-key'"'"'\n' >"$tmp/display.env"
export HOMEOS_DISPLAY_ENV="$tmp/display.env"
export HOMEOS_BOOT_FETCH="$tmp/fetch"
export HOMEOS_FETCH_URL_FILE="$tmp/url.txt"
export HOMEOS_BOOT_CUSTOM="$tmp/custom.mp4"
export HOMEOS_BOOT_INSTALLED="$tmp/installed.mp4"
play() { HOMEOS_BOOTSCREEN_DRY_RUN=1 "$player"; }
sync_video() { HOMEOS_FAKE_HTTP="$1" "$player" --sync 2>"$tmp/sync.log"; }

# Boot never downloads, even with a backend and nothing cached.
rm -f "$tmp/url.txt" "$tmp/cache.mp4"
out=$(HOMEOS_FAKE_HTTP=200 play)
printf '%s\n' "$out" | grep -qx "video=$tmp/installed.mp4" || fail "no cache did not play the built-in file"
[ ! -f "$tmp/url.txt" ] || fail "boot waited on a download"

# A missing remote video deletes a stale cache, so the built-in file plays.
printf 'xxxxftypiso' >"$tmp/cache.mp4"
rm -f "$tmp/url.txt"
sync_video 404 || fail "a missing remote video failed the sync"
[ ! -f "$tmp/cache.mp4" ] || fail "missing remote video left the cache in place"
grep -q '/storage/v1/object/boot-video/current.mp4$' "$tmp/url.txt" || fail "download URL is wrong"
if grep -q 'test-anon-key' "$tmp/url.txt" "$tmp/sync.log"; then
    fail "the anon key was printed"
fi
out=$(play)
printf '%s\n' "$out" | grep -qx "video=$tmp/installed.mp4" || fail "missing remote video did not fall back to the built-in file"

# A downloaded file wins over the built-in clip from the next boot.
sync_video 200 || fail "a download failed the sync"
[ "$(dd if="$tmp/cache.mp4" bs=1 skip=4 count=4 2>/dev/null || true)" = "ftyp" ] || fail "cache is not the downloaded mp4"
out=$(play)
printf '%s\n' "$out" | grep -qx "video=$tmp/cache.mp4" || fail "downloaded boot video was not used"

# Unchanged (304), a failed refresh, and a body that is not an MP4 all keep it.
sync_video 304 || fail "an unchanged video failed the sync"
[ -f "$tmp/cache.mp4" ] || fail "304 dropped the cache"
if sync_video 000; then
    fail "a failed download reported success"
fi
[ -f "$tmp/cache.mp4" ] || fail "a failed download discarded the cache"
if sync_video 200-html; then
    fail "a download that is not an MP4 reported success"
fi
[ "$(dd if="$tmp/cache.mp4" bs=1 skip=4 count=4 2>/dev/null || true)" = "ftyp" ] || fail "a bad download replaced the cache"
if ls "$tmp"/.boot.* >/dev/null 2>&1; then
    fail "the sync left a partial download behind"
fi

# No backend configured: the cache is not played, and there is nothing to fetch.
out=$(HOMEOS_DISPLAY_ENV="$tmp/missing.env" play)
printf '%s\n' "$out" | grep -qx "video=$tmp/installed.mp4" || fail "cache played without a backend"
rm -f "$tmp/url.txt"
HOMEOS_DISPLAY_ENV="$tmp/missing.env" sync_video 200 || fail "no backend failed the sync"
[ ! -f "$tmp/url.txt" ] || fail "downloaded with no backend configured"

# A file someone copied to the override path wins, and is not replaced.
printf 'local-override' >"$tmp/custom.mp4"
out=$(play)
printf '%s\n' "$out" | grep -qx "video=$tmp/custom.mp4" || fail "local override did not win"
sync_video 200 || fail "sync failed beside a local override"
[ "$(cat "$tmp/custom.mp4")" = "local-override" ] || fail "local override was overwritten"
rm -f "$tmp/custom.mp4"

# The real curl call. Every key goes in apikey; only a legacy JWT anon key is
# also the bearer token. sb_publishable_ keys are not JWTs.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
: >"${HOMEOS_CURL_ARGS:?}"
dest=
while [ $# -gt 0 ]; do
    printf '%s\n' "$1" >>"$HOMEOS_CURL_ARGS"
    if [ "$1" = -o ]; then dest=$2; fi
    shift
done
printf 'xxxxftypiso' >"$dest"
printf '200'
EOF
chmod +x "$tmp/bin/curl"
export HOMEOS_CURL_ARGS="$tmp/curl.args"
curl_sync() {
    printf 'HOMEOS_SUPABASE_URL=https://example.supabase.co/\nHOMEOS_SUPABASE_ANON_KEY=%s\n' "$1" >"$tmp/key.env"
    HOMEOS_BOOT_FETCH='' HOMEOS_DISPLAY_ENV="$tmp/key.env" PATH="$tmp/bin:$PATH" "$player" --sync 2>/dev/null
}
rm -f "$tmp/cache.mp4"
curl_sync sb_publishable_abc123 || fail "sync with a publishable key failed"
grep -qx 'apikey: sb_publishable_abc123' "$tmp/curl.args" || fail "publishable key was not sent as apikey"
if grep -q '^Authorization' "$tmp/curl.args"; then
    fail "publishable key was sent as a bearer token"
fi
grep -qx 'https://example.supabase.co/storage/v1/object/boot-video/current.mp4' "$tmp/curl.args" || fail "curl URL is wrong"
if grep -qx -- '-z' "$tmp/curl.args"; then
    fail "first download was conditional on a cache that does not exist"
fi
curl_sync eyJhbGciOiJIUzI1NiJ9.e30.sig || fail "sync with a legacy anon key failed"
grep -qx 'apikey: eyJhbGciOiJIUzI1NiJ9.e30.sig' "$tmp/curl.args" || fail "legacy key was not sent as apikey"
grep -qx 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig' "$tmp/curl.args" || fail "legacy anon key was not the bearer token"
grep -qx -- '-z' "$tmp/curl.args" || fail "a repeat check downloads the whole file again"

# The stop helper must end the player without asking systemd for a job.
sleep 30 &
pid=$!
HOMEOS_BOOTSCREEN_PID=$pid "$stop"
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "stop helper left the player running"
fi

# A player that takes a while to let go of the screen after TERM.
cat >"$tmp/bin/ffplay" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >"${HOMEOS_FAKE_PLAYER:?}.pid"
trap 'sleep 1; : >"$HOMEOS_FAKE_PLAYER.exited"; exit 0' TERM
while :; do sleep 0.1; done
EOF
chmod +x "$tmp/bin/ffplay"
printf 'x' >"$tmp/clip.mp4"
# $1: seconds to play first. Over 1.5 s the wrapper is blocked in `wait`.
start_wrapper() {
    rm -f "$tmp/player.pid" "$tmp/player.exited"
    HOMEOS_FAKE_PLAYER="$tmp/player" HOMEOS_BOOT_VIDEO="$tmp/clip.mp4" \
        HOMEOS_BOOT_TTY="$tmp/tty" HOMEOS_BOOT_DRM_TRIES=0 PATH="$tmp/bin:$PATH" \
        "$player" &
    wrapper=$!
    for _ in $(seq 1 50); do
        [ -s "$tmp/player.pid" ] && break
        sleep 0.1
    done
    [ -s "$tmp/player.pid" ] || fail "the wrapper did not start the player"
    sleep "$1"
}
player_gone() {
    [ -f "$tmp/player.exited" ] && ! kill -0 "$(cat "$tmp/player.pid")" 2>/dev/null
}

# The wrapper on its own (what systemctl stop signals) exits only after the
# player has.
start_wrapper 2
kill -TERM "$wrapper"
wait "$wrapper" || true
player_gone || fail "the wrapper exited while the player still held the screen"

# The real wrapper and the stop helper, as the kiosk runs them: once the
# video has played a while (the usual boot), and right after it started.
for settle in 2 0.3; do
    start_wrapper "$settle"
    HOMEOS_BOOTSCREEN_PID=$wrapper "$stop"
    if ! player_gone; then
        kill -KILL "$wrapper" "$(cat "$tmp/player.pid")" 2>/dev/null || true
        fail "stop helper returned while the player still held the screen ($settle s in)"
    fi
    if kill -0 "$wrapper" 2>/dev/null; then
        kill -KILL "$wrapper" 2>/dev/null || true
        fail "stop helper left the wrapper running ($settle s in)"
    fi
done

# A wrapper that dies at once and leaves its player behind: the helper still
# waits for the player, which is no longer under that pid.
rm -f "$tmp/player.pid" "$tmp/player.exited"
HOMEOS_FAKE_PLAYER="$tmp/player" bash -c '"$1" & wait' _ "$tmp/bin/ffplay" &
orphaner=$!
for _ in $(seq 1 50); do
    [ -s "$tmp/player.pid" ] && break
    sleep 0.1
done
[ -s "$tmp/player.pid" ] || fail "the stand-in wrapper did not start the player"
HOMEOS_BOOTSCREEN_PID=$orphaner "$stop"
[ -f "$tmp/player.exited" ] || fail "stop helper returned before an orphaned player exited"

echo "bootscreen ok"

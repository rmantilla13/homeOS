#!/usr/bin/env bash
# The boot screen's deploy side: the app draws the boot screen itself
# (tst_bootscreen covers that), so no player runs at boot and nothing hands
# HDMI over. This checks the units and the installer for that, the quiet
# console, the artwork, and the admin video download. No Pi or systemd: a
# stand-in replaces curl.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
sync="$root/display/deploy/homeos-boot-video-sync"
sync_unit="$root/display/deploy/homeos-boot-video-sync.service"
sync_timer="$root/display/deploy/homeos-boot-video-sync.timer"
display="$root/display/deploy/homeos-display.service"
preview_unit="$root/display/deploy/homeos-preview.service"
install="$root/display/deploy/install-pi.sh"
quiet="$root/display/deploy/quiet-boot.sh"
art="$root/display/resources/boot"

fail() { printf 'bootscreen test failed: %s\n' "$1" >&2; exit 1; }

bash -n "$sync" || fail "download script has a syntax error"
bash -n "$install" || fail "install-pi.sh has a syntax error"

# Comments stripped so a note mentioning a unit cannot satisfy a check.
unit_body() { sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*#/d' "$1"; }

# One owner of the screen during boot: no separate player, no handoff.
[ ! -e "$root/display/deploy/homeos-bootscreen.service" ] || fail "the boot video player unit is back"
if unit_body "$display" | grep -q 'bootscreen'; then
    fail "the kiosk still waits on or stops a boot video player"
fi
if unit_body "$preview_unit" | grep -q 'bootscreen'; then
    fail "preview still waits on or stops a boot video player"
fi
unit_body "$display" | grep -qx 'ExecStart=/usr/local/bin/homeos-display' || fail "kiosk start changed"
if unit_body "$display" | grep -q '^ExecStartPre='; then
    fail "the kiosk runs something before the app takes the screen"
fi

# Devices installed before this keep the old player enabled. Nothing stops
# it now, so it would hold HDMI: the installer has to disable and remove it
# before the new kiosk unit goes in.
retire_at="$(grep -n 'systemctl disable --now homeos-bootscreen' "$install" | head -1 | cut -d: -f1)"
kiosk_at="$(grep -n '/etc/systemd/system/homeos-display.service' "$install" | head -1 | cut -d: -f1)"
[ -n "$retire_at" ] || fail "installer does not disable the old boot video player"
[ -n "$kiosk_at" ] && [ "$retire_at" -lt "$kiosk_at" ] || fail "old player must be retired before the kiosk unit is installed"
grep -q 'rm -f /etc/systemd/system/homeos-bootscreen.service' "$install" || fail "installer leaves the old player's unit"
grep -q 'multi-user.target.wants/homeos-bootscreen.service' "$install" || fail "installer leaves the old player wanted at boot"
grep -q '/usr/local/libexec/homeos-stop-bootscreen' "$install" || fail "installer leaves the old stop helper"
if grep -Eq 'systemctl (enable|unmask|start)[^|]*homeos-bootscreen' "$install"; then
    fail "installer still enables the old player"
fi

# The admin's video downloads after boot, never during it.
unit_body "$sync_unit" | grep -qx 'ExecStart=/usr/local/libexec/homeos-boot-video-sync' || fail "download unit has the wrong start"
unit_body "$sync_unit" | grep -qx 'After=network-online.target' || fail "download runs before the network is up"
unit_body "$sync_unit" | grep -qx 'Wants=network-online.target' || fail "download does not ask for the network"
unit_body "$sync_unit" | grep -qx 'Type=oneshot' || fail "download unit is not a oneshot"
unit_body "$sync_timer" | grep -qx 'WantedBy=timers.target' || fail "download timer is not enabled with the timers"
unit_body "$sync_timer" | grep -q '^OnBootSec=' || fail "download timer does not run after boot"
unit_body "$sync_timer" | grep -q '^OnUnitActiveSec=' || fail "download timer does not check again later"
grep -q 'homeos-boot-video-sync.service' "$install" || fail "installer does not install the download unit"
grep -q 'display/deploy/homeos-boot-video-sync"' "$install" || fail "installer does not install the download script"
grep -q 'enable --now homeos-boot-video-sync.timer' "$install" || fail "installer does not start the download timer"
grep -q ' curl ' "$install" || fail "installer does not install curl"
grep -q '/etc/homeos/boot.mp4' "$install" || fail "installer does not document the local video path"

# Quiet boot lives in quiet-boot.sh (kiosk_boot_test.sh runs it on sample
# files); the installer has to call it.
grep -Fq 'display/deploy/quiet-boot.sh' "$install" || fail "installer does not run quiet-boot.sh"
grep -q 'set_config_key disable_splash 1' "$quiet" || fail "quiet boot does not hide the rainbow splash"
for opt in quiet logo.nologo systemd.show_status=false loglevel=3 plymouth.enable=0 vt.global_cursor_default=0; do
    grep -qx "    $opt" "$quiet" || fail "quiet boot does not set $opt"
done
grep -qx 'console_vt=console=tty3' "$quiet" || fail "boot text is not sent to tty3"
grep -qx 'drop_options=(splash)' "$quiet" || fail "quiet boot does not drop the Plymouth splash"
grep -q '99-homeos-quiet.cfg' "$install" || fail "installer does not silence cloud-init logs"
grep -q 'cloud-final.service' "$install" || fail "installer does not override cloud-final"
grep -q 'StandardOutput=journal' "$install" || fail "installer does not take cloud-init off the console"

# The artwork the app draws: PNGs for a 1920x1200 stage, the highlight square.
png_size() {
    local sig
    sig=$(od -An -tx1 -N8 "$1" | tr -d ' \n')
    [ "$sig" = 89504e470d0a1a0a ] || return 1
    printf '%d %d\n' "0x$(od -An -tx1 -j16 -N4 "$1" | tr -d ' \n')" "0x$(od -An -tx1 -j20 -N4 "$1" | tr -d ' \n')"
}
for layer in background mark; do
    [ "$(png_size "$art/$layer.png")" = "1920 1200" ] || fail "$layer.png is not a 1920x1200 PNG"
done
[ "$(png_size "$art/highlight.png")" = "560 560" ] || fail "highlight.png is not a 560x560 PNG"
total=$(cat "$art"/*.png | wc -c)
[ "$total" -lt 1500000 ] || fail "boot artwork is too large ($total bytes)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
export HOMEOS_BOOT_CACHE="$tmp/cache.mp4"

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
sync_video() { HOMEOS_FAKE_HTTP="$1" "$sync" 2>"$tmp/sync.log"; }

# A missing remote video deletes a stale cache, so the logo shows.
printf 'xxxxftypiso' >"$tmp/cache.mp4"
rm -f "$tmp/url.txt"
sync_video 404 || fail "a missing remote video failed the sync"
[ ! -f "$tmp/cache.mp4" ] || fail "missing remote video left the cache in place"
grep -q '/storage/v1/object/boot-video/current.mp4$' "$tmp/url.txt" || fail "download URL is wrong"
if grep -q 'test-anon-key' "$tmp/url.txt" "$tmp/sync.log"; then
    fail "the anon key was printed"
fi

# A download lands where the app looks for it (BootScreen.cpp), readable by
# the app's user.
sync_video 200 || fail "a download failed the sync"
[ "$(dd if="$tmp/cache.mp4" bs=1 skip=4 count=4 2>/dev/null || true)" = "ftyp" ] || fail "cache is not the downloaded mp4"
[ "$(stat -c %a "$tmp/cache.mp4")" = 644 ] || fail "the downloaded video is not world-readable"
grep -q '"/var/lib/homeos/boot.mp4"' "$root/display/src/hardware/BootScreen.cpp" || fail "the app does not read the download path"
grep -q 'cache="${HOMEOS_BOOT_CACHE:-/var/lib/homeos/boot.mp4}"' "$sync" || fail "the download path moved"

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

# No backend configured: there is nothing to fetch.
rm -f "$tmp/url.txt"
HOMEOS_DISPLAY_ENV="$tmp/missing.env" sync_video 200 || fail "no backend failed the sync"
[ ! -f "$tmp/url.txt" ] || fail "downloaded with no backend configured"

# A file someone copied to the override path is never replaced.
printf 'local-override' >"$tmp/custom.mp4"
HOMEOS_BOOT_CUSTOM="$tmp/custom.mp4" sync_video 200 || fail "sync failed beside a local override"
[ "$(cat "$tmp/custom.mp4")" = "local-override" ] || fail "local override was overwritten"
rm -f "$tmp/custom.mp4"
if "$sync" --sync 2>/dev/null; then
    fail "an unknown argument was accepted"
fi

# The real curl call. Every key goes in apikey; only a legacy JWT anon key is
# also the bearer token. sb_publishable_ keys are not JWTs.
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
    HOMEOS_BOOT_FETCH='' HOMEOS_DISPLAY_ENV="$tmp/key.env" PATH="$tmp/bin:$PATH" "$sync" 2>/dev/null
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

echo "bootscreen ok"

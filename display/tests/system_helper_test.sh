#!/usr/bin/env bash
# The Wi-Fi helper must pass names through to nmcli without a shell, and must
# refuse anything that isn't a Wi-Fi change or a reboot.
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/deploy/homeos-system"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/log"

cat > "$tmp/nmcli" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOMEOS_LOG"
i=1
for arg in "$@"; do
    printf 'ARG %s\n' "$arg" >> "$HOMEOS_LOG"
    if [ "$arg" = "password-file" ]; then
        next=$((i + 1))
        eval "file=\${$next}"
        printf 'PW %s\n' "$(cat "$file")" >> "$HOMEOS_LOG"
    fi
    i=$((i + 1))
done
exit 0
EOF
cat > "$tmp/systemctl" << 'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$HOMEOS_LOG"
exit 0
EOF
chmod 755 "$tmp/nmcli" "$tmp/systemctl"

export PATH="$tmp:$PATH"
export HOMEOS_LOG="$log"

fail() { printf 'helper test failed: %s\n' "$1" >&2; exit 1; }

: > "$log"
"$helper" wifi-status >/dev/null
grep -q 'ARG radio' "$log" || fail "wifi-status did not ask for the radio"
grep -q 'ARG device' "$log" || fail "wifi-status did not ask for devices"

: > "$log"
"$helper" wifi-radio on
grep -qx 'ARG on' "$log" || fail "wifi-radio on was not passed through"
if "$helper" wifi-radio maybe >/dev/null 2>"$tmp/err"; then
    fail "wifi-radio accepted a bad value"
fi
grep -q 'need on or off' "$tmp/err"

: > "$log"
printf '%s' 'correct horse' | "$helper" wifi-connect 'Cafe:Bar' psk
grep -q 'ARG Cafe:Bar' "$log" || fail "SSID was not passed through intact"
grep -q 'PW correct horse' "$log" || fail "password file was not given to nmcli"
if grep '^ARG ' "$log" | grep -q 'correct horse'; then
    fail "password appeared in nmcli arguments"
fi

: > "$log"
if "$helper" wifi-connect '-sneaky' psk >/dev/null 2>"$tmp/err"; then
    fail "SSID starting with a dash was accepted"
fi
grep -q "isn't usable" "$tmp/err"
[ ! -s "$log" ] || fail "nmcli ran for a rejected SSID"

: > "$log"
if printf '%s\n' 'secret' | "$helper" wifi-connect "$(printf 'bad\nname')" psk >/dev/null 2>"$tmp/err"; then
    fail "SSID with a newline was accepted"
fi

# A name that looks like shell must stay a name.
: > "$log"
payload='$(touch /tmp/hos-pwn)'
printf '%s' 'pw' | "$helper" wifi-connect "$payload" psk
[ ! -e /tmp/hos-pwn ] || fail "SSID was executed by a shell"
grep -q "ARG $payload" "$log" || fail "shell-looking SSID was not passed literally"

: > "$log"
"$helper" wifi-connect 'Home' saved
grep -q 'ARG connection' "$log" || fail "saved network did not bring the profile up"
grep -q 'ARG Home' "$log" || fail "saved SSID missing"

: > "$log"
"$helper" reboot
grep -qx 'systemctl reboot' "$log" || fail "reboot did not call systemctl reboot"
if "$helper" reboot now >/dev/null 2>"$tmp/err"; then
    fail "reboot accepted an argument"
fi

echo "homeos-system helper ok"

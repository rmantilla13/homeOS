#!/usr/bin/env bash
# The kiosk must be enabled and started by install-pi.sh, and the unit must
# take tty1 from getty. No Pi or systemd required: the decision block in
# install-pi.sh is run against a fake systemctl and the pi-sim stub.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
unit="$root/display/deploy/homeos-display.service"
pam="$root/display/deploy/homeos-display.pam"
install="$root/display/deploy/install-pi.sh"
preview="$root/display/deploy/preview.sh"
preview_unit="$root/display/deploy/homeos-preview.service"
stub="$root/display/deploy/pi-sim/systemctl-stub"

fail() { printf 'kiosk boot test failed: %s\n' "$1" >&2; exit 1; }

# Comments stripped so a note mentioning getty cannot satisfy a directive.
unit_body() { sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*#/d' "$unit"; }

directive() {
    unit_body | grep -Eq "$1" || fail "unit missing: $1"
}

directive '^Conflicts=.*getty@tty1\.service'
directive '^Conflicts=.*autovt@tty1\.service'
directive '^Before=.*getty@tty1\.service'
directive '^Before=.*autovt@tty1\.service'
if unit_body | grep -Eq '^After=.*getty@'; then
    fail "After=getty lets the login prompt win the boot transaction"
fi
directive '^StandardInput=tty$'
directive '^TTYPath=/dev/tty1$'
directive '^TTYReset=yes$'
directive '^TTYVHangup=yes$'
directive '^TTYVTDisallocate=yes$'
directive '^UtmpIdentifier=tty1$'
directive '^PAMName=homeos-display$'
directive '^Restart=always$'
directive '^StartLimitIntervalSec=0$'
directive '^\[Install\]$'
directive '^WantedBy=multi-user\.target$'
directive '^Wants=user@@UID@\.service$'
directive '^After=user@@UID@\.service$'
directive '^After=systemd-udev-trigger\.service$'
directive '^Wants=systemd-logind\.service$'
directive '^Environment=XDG_RUNTIME_DIR=/run/user/@UID@$'
directive '^User=@USER@$'
directive '^ExecStart=/usr/local/bin/homeos-display$'
directive '^SupplementaryGroups=video render input audio tty$'
directive '^Environment=QT_QPA_PLATFORM=eglfs$'
directive '^Environment=QT_QPA_EGLFS_INTEGRATION=eglfs_kms$'
directive '^Environment=QT_QPA_EGLFS_KMS_CONFIG=/etc/homeos/kms.json$'
directive '^Environment=QT_QPA_EGLFS_ALWAYS_SET_MODE=1$'
if unit_body | grep -Eq '^After=.*network-online|^Wants=network-online'; then
    fail "waiting for network-online leaves the panel on the console"
fi

# Any account the installer is logged in as. The unit must not name a person.
filled="$(sed -e 's/@USER@/pi/g' -e 's/@UID@/1000/g' "$unit")"
printf '%s\n' "$filled" | grep -qx 'User=pi' || fail "User= was not substituted"
printf '%s\n' "$filled" | grep -qx 'Wants=user@1000.service' || fail "user manager unit was not substituted"
printf '%s\n' "$filled" | grep -qx 'After=user@1000.service' || fail "After=user@ was not substituted"
printf '%s\n' "$filled" | grep -qx 'Environment=XDG_RUNTIME_DIR=/run/user/1000' || fail "runtime dir was not substituted"
if printf '%s\n' "$filled" | grep -q '@USER@\|@UID@'; then
    fail "placeholder left after substitution"
fi

grep -q 'session[[:space:]]*required[[:space:]]*pam_systemd.so' "$pam" || fail "pam stack does not open a logind session"
grep -q 'auth[[:space:]]*required[[:space:]]*pam_permit.so' "$pam" || fail "pam stack must not ask for a password"

grep -Fq 's/@USER@/$user/g' "$install" || fail "install script dropped user substitution"
grep -Fq 's/@UID@/$uid/g' "$install" || fail "install script dropped uid substitution"
grep -q 'homeos-display.pam' "$install" || fail "install script does not install the pam stack"
grep -q 'loginctl enable-linger' "$install" || fail "install script dropped linger"
grep -Fq 'systemctl start "user@${uid}.service"' "$install" || fail "install script does not start the user manager"
grep -q 'set-default multi-user.target' "$install" || fail "install script no longer forces the console target"

grep -q 'Conflicts=homeos-display.service' "$preview_unit" || fail "preview no longer conflicts with the kiosk"
grep -q 'disable --now homeos-display' "$preview" || fail "preview on does not stop the kiosk"
grep -q 'enable --now homeos-preview' "$preview" || fail "preview on does not enable itself"
grep -q 'disable --now homeos-preview' "$preview" || fail "preview off does not disable itself"
grep -q 'enable --now homeos-display' "$preview" || fail "preview off does not restore the kiosk"
grep -q 'restart homeos-display' "$preview" || fail "preview off does not start the kiosk"

# The unit file is copied, then reloaded, then enabled.
unit_at="$(grep -n '/etc/systemd/system/homeos-display.service' "$install" | head -1 | cut -d: -f1)"
reload_at="$(grep -n 'daemon-reload' "$install" | head -1 | cut -d: -f1)"
enable_at="$(grep -n 'enable --now homeos-display' "$install" | head -1 | cut -d: -f1)"
[ -n "$unit_at" ] && [ -n "$reload_at" ] && [ -n "$enable_at" ] || fail "missing install, reload, or enable"
[ "$unit_at" -lt "$reload_at" ] && [ "$reload_at" -lt "$enable_at" ] || fail "unit must be installed and reloaded before enable"

block="$(awk '/# kiosk-boot-begin/,/# kiosk-boot-end/' "$install")"
[ -n "$block" ] || fail "kiosk boot block not found in install-pi.sh"
printf '%s\n' "$block" | grep -q 'systemctl enable --now homeos-display' || fail "boot block does not enable and start the kiosk"
printf '%s\n' "$block" | grep -q 'systemctl restart homeos-display' || fail "boot block does not reload a running kiosk"
printf '%s\n' "$block" | grep -q 'systemctl disable getty@tty1' || fail "boot block leaves the login prompt enabled"
printf '%s\n' "$block" | grep -q 'systemctl stop getty@tty1' || fail "boot block does not release tty1 before start"
stop_at=$(printf '%s\n' "$block" | grep -n 'systemctl stop getty@tty1' | head -1 | cut -d: -f1)
now_at=$(printf '%s\n' "$block" | grep -n 'systemctl enable --now homeos-display' | head -1 | cut -d: -f1)
[ -n "$stop_at" ] && [ -n "$now_at" ] && [ "$stop_at" -lt "$now_at" ] || fail "getty must be stopped before the kiosk starts"
if printf '%s\n' "$block" | grep -q 'is-active'; then
    fail "boot block still starts the kiosk only when it is already active"
fi

# preview_on: is-enabled homeos-preview succeeds. restart_rc: what `restart` returns.
run_block() {
    local log="$1" preview_on="$2" restart_rc="$3" enable_rc="${4:-0}"
    : >"$log"
    systemctl() {
        printf '%s\n' "$*" >>"$log"
        case "$1" in
            is-enabled)
                if [ "$preview_on" = 1 ]; then return 0; fi
                return 3
                ;;
            enable) return "$enable_rc" ;;
            restart) return "$restart_rc" ;;
            *) return 0 ;;
        esac
    }
    sudo() { "$@"; }
    # shellcheck disable=SC1090
    source /dev/stdin <<<"$block"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Not enabled yet (a fresh install, or a previous one that never enabled it).
run_block "$tmp/log" 0 0
grep -qx 'unmask homeos-display' "$tmp/log" || fail "fresh install did not unmask"
grep -qx 'enable --now homeos-display' "$tmp/log" || fail "fresh install did not enable and start"
grep -qx 'restart homeos-display' "$tmp/log" || fail "fresh install did not reload the kiosk"
grep -qx 'disable getty@tty1.service' "$tmp/log" || fail "fresh install did not disable the login prompt"
grep -qx 'stop getty@tty1.service autovt@tty1.service' "$tmp/log" || fail "fresh install did not stop the login prompt"
if grep -qx 'disable --now homeos-display' "$tmp/log"; then
    fail "fresh install disabled the kiosk"
fi

# Already installed: enable again and restart so the new binary is what is on screen.
run_block "$tmp/log" 0 0
grep -qx 'enable --now homeos-display' "$tmp/log" || fail "update did not enable and start"
grep -qx 'restart homeos-display' "$tmp/log" || fail "update did not restart"

# The panel is not up yet, so the start command fails. The unit must still be
# enabled, and the installer must keep going (Restart= retries).
if ! run_block "$tmp/log" 0 1; then
    fail "a failed restart aborted the boot block"
fi
grep -qx 'enable --now homeos-display' "$tmp/log" || fail "failed restart skipped enable"
grep -qx 'restart homeos-display' "$tmp/log" || fail "failed restart skipped the start"

# enable --now itself failed. Still restart, and do not abort the installer.
if ! run_block "$tmp/log" 0 0 1; then
    fail "a failed enable --now aborted the boot block"
fi
grep -qx 'enable --now homeos-display' "$tmp/log" || fail "failed enable was not attempted"
grep -qx 'restart homeos-display' "$tmp/log" || fail "failed enable skipped the start"

# Preview mode is what was enabled: leave the kiosk off.
run_block "$tmp/log" 1 0
grep -qx 'disable --now homeos-display' "$tmp/log" || fail "preview mode did not keep the kiosk off"
if grep -q 'enable --now homeos-display' "$tmp/log"; then
    fail "preview mode enabled the kiosk"
fi
if grep -qx 'restart homeos-display' "$tmp/log"; then
    fail "preview mode started the kiosk"
fi

# pi-install CI uses this stub: nothing is enabled, so the block must enable and start.
# Drop the fake systemctl function so this run actually executes the stub.
unset -f systemctl
stubdir="$tmp/bin"
mkdir -p "$stubdir"
cp "$stub" "$stubdir/systemctl"
chmod +x "$stubdir/systemctl"
stub_out="$(
    sudo() { "$@"; }
    PATH="$stubdir:${PATH:-/usr/bin:/bin}"
    # shellcheck disable=SC1090
    source /dev/stdin <<<"$block" 2>&1
)" || fail "boot block failed under the systemctl stub"
printf '%s\n' "$stub_out" | grep -q 'systemctl enable --now homeos-display' || fail "stub path did not enable and start"
printf '%s\n' "$stub_out" | grep -q 'systemctl restart homeos-display' || fail "stub path did not reload the kiosk"
if printf '%s\n' "$stub_out" | grep -q 'systemctl disable.*homeos-display'; then
    fail "stub path disabled the kiosk"
fi
printf '%s\n' "$stub_out" | grep -q 'systemctl disable getty@tty1' || fail "stub path left the login prompt enabled"
printf '%s\n' "$stub_out" | grep -q 'systemctl stop getty@tty1' || fail "stub path did not release tty1"

grep -q 'NAutoVTs=0' "$install" || fail "installer does not stop logind from spawning a login on tty1"
grep -q 'QT_QPA_EGLFS_ALWAYS_SET_MODE=1' "$install" || fail "installer does not force Qt to set the HDMI mode"
grep -q 'ensure_display_env QT_QPA_EGLFS_KMS_CONFIG' "$install" || fail "installer does not repair a stale display.env"
docs="$root/docs/PI_SETUP.md"
grep -q 'only shows logs' "$docs" || fail "docs do not say journalctl only shows logs"
grep -q 'sudo systemctl enable --now homeos-display' "$docs" || fail "docs do not say how to put homeOS on HDMI"
grep -q 'cursor/display-boot-video-e66c' "$docs" || fail "docs do not name the branch that installs the unit"
if grep -q 'should not need' "$docs"; then
    fail "docs still tell them not to start the kiosk"
fi

pick="$(awk '/# kms-pick-begin/,/# kms-pick-end/' "$install")"
[ -n "$pick" ] || fail "hdmi pick function not found"
# shellcheck disable=SC1090
source /dev/stdin <<<"$pick"

sys="$(mktemp -d)"
out=$(homeos_pick_hdmi "$sys")
printf '%s\n' "$out" | grep -qx '/dev/dri/card1' || fail "missing DRM nodes did not fall back to card1"
printf '%s\n' "$out" | grep -qx 'HDMI1' || fail "missing DRM nodes did not fall back to HDMI1"

mkdir -p "$sys/card1-HDMI-A-1" "$sys/card1-HDMI-A-2"
printf 'disconnected\n' >"$sys/card1-HDMI-A-1/status"
printf 'connected\n' >"$sys/card1-HDMI-A-2/status"
out=$(homeos_pick_hdmi "$sys")
printf '%s\n' "$out" | grep -qx '/dev/dri/card1' || fail "connected HDMI-A-2 used the wrong card"
printf '%s\n' "$out" | grep -qx 'HDMI2' || fail "connected HDMI-A-2 was not Qt HDMI2"

printf 'connected\n' >"$sys/card1-HDMI-A-1/status"
out=$(homeos_pick_hdmi "$sys")
printf '%s\n' "$out" | grep -qx 'HDMI1' || fail "HDMI0 (HDMI-A-1) did not win when both ports are connected"

printf 'disconnected\n' >"$sys/card1-HDMI-A-1/status"
printf 'disconnected\n' >"$sys/card1-HDMI-A-2/status"
out=$(homeos_pick_hdmi "$sys")
printf '%s\n' "$out" | grep -qx 'HDMI1' || fail "panel-off fallback was not HDMI0"

rm -rf "$sys/card1-HDMI-A-1" "$sys/card1-HDMI-A-2"
mkdir -p "$sys/card0-HDMI-A-1"
printf 'connected\n' >"$sys/card0-HDMI-A-1/status"
out=$(homeos_pick_hdmi "$sys")
printf '%s\n' "$out" | grep -qx '/dev/dri/card0' || fail "HDMI card index was pinned"
rm -rf "$sys"

echo "kiosk boot ok"

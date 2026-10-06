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
grep -Fq '/etc/ssh/sshd_config.d/homeos.conf' "$install" || fail "install script dropped the sshd drop-in"
grep -Fq 'IPQoS cs0 cs0' "$install" || fail "install script dropped IPQoS cs0 cs0"
grep -Fq 'UseDNS no' "$install" || fail "install script dropped UseDNS no"
grep -Fq 'chmod 644 /etc/ssh/sshd_config.d/homeos.conf' "$install" || fail "sshd drop-in is not mode 644"
grep -Fq 'systemctl reload ssh' "$install" || fail "install script does not reload ssh"
grep -Fq 'wifi.powersave = 2' "$install" || fail "install script dropped Wi-Fi power save"

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
if printf '%s\n' "$stub_out" | grep -q 'systemctl disable'; then
    fail "stub path disabled the kiosk"
fi

echo "kiosk boot ok"

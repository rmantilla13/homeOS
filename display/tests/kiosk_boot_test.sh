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
if unit_body | grep -q 'network-online'; then
    fail "kiosk waits for the network, so the panel stays blank until Wi-Fi"
fi
directive '^StandardInput=tty$'
directive '^TTYPath=/dev/tty1$'
directive '^TTYReset=yes$'
directive '^TTYVHangup=yes$'
directive '^TTYVTDisallocate=yes$'
directive '^UtmpIdentifier=tty1$'
directive '^PAMName=homeos-display$'
directive '^Restart=always$'
directive '^RestartSec=1$'
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

grep -Fq 'quiet-boot.sh' "$install" || fail "install script does not quiet the boot console"
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

quiet="$root/display/deploy/quiet-boot.sh"
[ -x "$quiet" ] || fail "quiet-boot.sh is not executable"

# A stock Pi cmdline: kernel text on tty1, Plymouth splash, no quiet options.
stock='console=serial0,115200 console=tty1 root=PARTUUID=abcd-02 rootfstype=ext4 fsck.repair=yes rootwait splash'
printf '%s\n' "$stock" >"$tmp/cmdline.txt"
printf '%s\n' '# comments stay' 'disable_splash=0' 'boot_delay=1' >"$tmp/config.txt"
"$quiet" "$tmp/cmdline.txt" "$tmp/config.txt" >"$tmp/quiet.out"
got="$(cat "$tmp/cmdline.txt")"
printf '%s\n' "$got" | grep -q 'console=tty1' || fail "quiet boot moved off tty1, which the kiosk owns"
printf '%s\n' "$got" | grep -q 'console=serial0,115200' || fail "serial console was dropped"
printf '%s\n' "$got" | grep -q 'root=PARTUUID=abcd-02' || fail "root device was dropped"
for opt in quiet loglevel=3 logo.nologo systemd.show_status=false consoleblank=0 vt.global_cursor_default=0; do
    printf '%s\n' "$got" | grep -Fq "$opt" || fail "cmdline missing $opt"
done
if printf '%s\n' "$got" | grep -Eq '(^| )splash( |$)'; then
    fail "Plymouth splash still starts"
fi
grep -qx 'disable_splash=1' "$tmp/config.txt" || fail "rainbow splash stays on"
grep -qx 'boot_delay=0' "$tmp/config.txt" || fail "firmware boot delay stays"
grep -qx 'boot_delay_ms=0' "$tmp/config.txt" || fail "firmware boot delay in ms stays"
grep -qx '# comments stay' "$tmp/config.txt" || fail "config.txt comments were dropped"
[ -f "$tmp/cmdline.txt.homeos-backup" ] || fail "cmdline backup was not kept"
[ -f "$tmp/config.txt.homeos-backup" ] || fail "config backup was not kept"

# Already quiet, including a duplicate and an old log level. Second run is a no-op.
printf '%s\n' 'console=tty1 quiet quiet loglevel=7 logo.nologo systemd.show_status=false consoleblank=0 vt.global_cursor_default=0' >"$tmp/cmdline2.txt"
printf '%s\n' 'disable_splash=1' 'boot_delay=0' 'boot_delay_ms=0' >"$tmp/config2.txt"
"$quiet" "$tmp/cmdline2.txt" "$tmp/config2.txt" >"$tmp/quiet2.out"
once="$(cat "$tmp/cmdline2.txt")"
printf '%s\n' "$once" | grep -q 'loglevel=3' || fail "old log level was kept"
if printf '%s\n' "$once" | grep -q 'loglevel=7'; then
    fail "old log level still present"
fi
# quiet once, not twice
quiet_count="$(printf '%s\n' "$once" | tr ' ' '\n' | grep -cx 'quiet' || true)"
[ "$quiet_count" -eq 1 ] || fail "quiet was duplicated ($quiet_count)"
backup_before="$(cat "$tmp/cmdline2.txt.homeos-backup")"
"$quiet" "$tmp/cmdline2.txt" "$tmp/config2.txt" >"$tmp/quiet3.out"
[ "$(cat "$tmp/cmdline2.txt")" = "$once" ] || fail "second quiet-boot run rewrote cmdline"
[ ! -s "$tmp/quiet3.out" ] || fail "second quiet-boot run reported a change"
[ "$(cat "$tmp/cmdline2.txt.homeos-backup")" = "$backup_before" ] || fail "second quiet-boot run replaced the backup"

# boot_delay must not rewrite boot_delay_ms, and a cmdline with no trailing
# newline (how some images ship it) still updates.
printf '%s' 'console=tty1 quiet splash plymouth.ignore-serial-consoles' >"$tmp/cmdline3.txt"
printf '%s' $'boot_delay_ms=5\n#keep\n' >"$tmp/config3.txt"
"$quiet" "$tmp/cmdline3.txt" "$tmp/config3.txt" >/dev/null
got3="$(cat "$tmp/cmdline3.txt")"
printf '%s\n' "$got3" | grep -Fq 'plymouth.ignore-serial-consoles' || fail "plymouth serial flag was dropped"
if printf '%s\n' "$got3" | grep -Eq '(^| )splash( |$)'; then
    fail "splash stayed on a Pi OS cmdline"
fi
grep -qx 'boot_delay=0' "$tmp/config3.txt" || fail "boot_delay was not set beside boot_delay_ms"
grep -qx '#keep' "$tmp/config3.txt" || fail "config comment beside boot_delay_ms was dropped"
# The ms key must stay the ms key. Matching boot_delay as a prefix would
# rewrite this line into boot_delay=0.
[ "$(head -1 "$tmp/config3.txt")" = "boot_delay_ms=0" ] || fail "boot_delay matched boot_delay_ms"

# No firmware files: the installer still finishes (a container, or not a Pi).
"$quiet" "$tmp/missing-cmdline.txt" "$tmp/missing-config.txt" >"$tmp/missing.out"
grep -q 'skipping console setup' "$tmp/missing.out" || fail "missing cmdline did not skip"

echo "kiosk boot ok"

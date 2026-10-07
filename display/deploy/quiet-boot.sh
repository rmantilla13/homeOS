#!/usr/bin/env bash
# Makes a Raspberry Pi boot straight to the Ohana panel: no rainbow splash,
# no boot text, no Plymouth logo, no cursor. The panel stays black until the
# app draws its boot screen. Safe to re-run. Originals are kept once, as
# <file>.homeos-backup.
#
#   quiet-boot.sh [cmdline.txt] [config.txt]
set -euo pipefail

cmdline="${1:-/boot/firmware/cmdline.txt}"
config="${2:-/boot/firmware/config.txt}"

if [ ! -f "$cmdline" ]; then
    echo "$cmdline not found (not a Raspberry Pi?); skipping console setup"
    exit 0
fi

write_file() {
    local dest="$1"
    if [ -w "$dest" ]; then
        cat >"$dest"
    else
        sudo tee "$dest" >/dev/null
    fi
}

backup_once() {
    local src="$1"
    local dest="${src}.homeos-backup"
    [ -f "$dest" ] && return 0
    if [ -w "$(dirname "$src")" ]; then
        cp -a "$src" "$dest"
    else
        sudo cp -a "$src" "$dest"
    fi
}

# The kernel console (/dev/console) goes to tty3, which is never on screen.
# tty1 is the VT the panel shows and the kiosk binds. quiet and loglevel only
# cover kernel messages: the initramfs fsck, systemd-fsck, cloud-init and
# anything else with StandardOutput=console write to /dev/console directly,
# and an emergency shell opens there too (Ctrl+Alt+F3 with a keyboard).
# Serial consoles are left alone.
console_vt=console=tty3
keep_options=(
    quiet
    loglevel=3
    logo.nologo
    systemd.show_status=false
    plymouth.enable=0
    consoleblank=0
    vt.global_cursor_default=0
)
# Plymouth holds the display until it quits, so the Pi logo sits there
# instead of the boot video or Ohana, and the video player can't open the
# screen. Drop the flag that starts it; plymouth.enable=0 above keeps it off
# if something adds splash back.
drop_options=(splash)

apply_cmdline() {
    local line="" words=() word option key new=() seen drop filtered=()
    IFS= read -r line <"$cmdline" || true
    if [ -n "$line" ]; then
        read -ra words <<<"$line"
    fi

    for word in "${words[@]+"${words[@]}"}"; do
        drop=0
        for option in "${drop_options[@]}"; do
            if [ "$word" = "$option" ]; then
                drop=1
                break
            fi
        done
        [ "$drop" -eq 0 ] && filtered+=("$word")
    done
    words=("${filtered[@]+"${filtered[@]}"}")

    # Every VT console becomes tty3, once, where the first one was. The last
    # console= is /dev/console, so with serial0 first the VT still gets it.
    # No VT console at all would mean the kernel default, tty1.
    filtered=()
    seen=0
    for word in "${words[@]+"${words[@]}"}"; do
        if [[ "$word" =~ ^console=tty[0-9]+$ ]]; then
            [ "$seen" -eq 0 ] && filtered+=("$console_vt")
            seen=1
        else
            filtered+=("$word")
        fi
    done
    [ "$seen" -eq 1 ] || filtered+=("$console_vt")
    words=("${filtered[@]+"${filtered[@]}"}")

    for option in "${keep_options[@]}"; do
        key="${option%%=*}"
        new=()
        seen=0
        for word in "${words[@]+"${words[@]}"}"; do
            if [ "${word%%=*}" = "$key" ]; then
                if [ "$seen" -eq 0 ]; then
                    new+=("$option")
                    seen=1
                fi
            else
                new+=("$word")
            fi
        done
        if [ "$seen" -eq 0 ]; then
            new+=("$option")
        fi
        words=("${new[@]+"${new[@]}"}")
    done

    local updated=""
    if [ "${#words[@]}" -gt 0 ]; then
        updated="${words[*]}"
    fi
    if [ "$updated" = "$line" ]; then
        return 0
    fi
    backup_once "$cmdline"
    printf '%s\n' "$updated" | write_file "$cmdline"
    echo "Updated $cmdline for a quiet boot (takes effect after a reboot)"
}

set_config_key() {
    local key="$1" value="$2" file="$3"
    [ -f "$file" ] || return 0
    local tmp found=0 updated=0 line
    # A new key goes above the first [pi4] / [cm4] / [all] filter, so it
    # applies to every model instead of only the last section in the file.
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        found=1
    fi
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$found" -eq 0 ] && [[ "$line" =~ ^[[:space:]]*\[ ]]; then
            printf '%s=%s\n' "$key" "$value"
            found=1
            updated=1
        fi
        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            found=1
            if [ "$line" = "${key}=${value}" ]; then
                printf '%s\n' "$line"
            else
                printf '%s\n' "${key}=${value}"
                updated=1
            fi
        else
            printf '%s\n' "$line"
        fi
    done <"$file" >"$tmp"
    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
        updated=1
    fi
    if [ "$updated" -eq 1 ]; then
        backup_once "$file"
        write_file "$file" <"$tmp"
        echo "Set ${key}=${value} in $file (takes effect after a reboot)"
    fi
    rm -f "$tmp"
}

apply_cmdline
# Rainbow square (firmware) and the firmware's pause before the kernel.
set_config_key disable_splash 1 "$config"
set_config_key boot_delay 0 "$config"
set_config_key boot_delay_ms 0 "$config"

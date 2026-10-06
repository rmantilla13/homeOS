#!/usr/bin/env bash
# Makes a Raspberry Pi boot straight to the homeOS panel: no rainbow splash,
# no kernel log on the console, no Plymouth logo. The kiosk service then
# paints as soon as the screen and the user session exist. Safe to re-run.
# Originals are kept once, as <file>.homeos-backup.
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

# tty1 stays the kernel console. It is the foreground VT the panel shows,
# and the kiosk binds that same VT. These options leave it blank.
keep_options=(
    quiet
    loglevel=3
    logo.nologo
    systemd.show_status=false
    consoleblank=0
    vt.global_cursor_default=0
)
# Plymouth holds the display until it quits, so the Pi logo sits there
# instead of homeOS. Drop the flag that starts it.
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
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
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

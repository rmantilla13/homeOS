#!/usr/bin/env bash
# Preview mode: use Ohana on the Pi before the panel is connected. The app
# draws to a virtual 1920x1200 screen that you open in a web browser on your
# computer; the mouse works as touch.
#
#   ./display/deploy/preview.sh on          # start it (and on every boot)
#   ./display/deploy/preview.sh on --lan    # also reachable from your network, with a password
#   ./display/deploy/preview.sh off         # back to the kiosk on the real panel
#   ./display/deploy/preview.sh status
#
# Run install-pi.sh first. Preview and the kiosk never run at the same time.
set -euo pipefail

if [ "$(uname -s)" != Linux ]; then
    echo "This runs on the Raspberry Pi. Log in to it first (ssh <user>@homeos.local)." >&2
    exit 1
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
user="$(id -un)"
host="$(hostname).local"
web_port=6080
url_path="vnc.html?autoconnect=1&resize=scale"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user; it uses sudo where needed." >&2
    exit 1
fi

cmd="${1:-}"
lan=0
case "${2:-}" in
    "") ;;
    --lan) [ "$cmd" = on ] || usage; lan=1 ;;
    *) usage ;;
esac

case "$cmd" in
on)
    if [ ! -x /usr/local/bin/homeos-display ]; then
        echo "Ohana isn't installed yet. Run ./display/deploy/install-pi.sh first." >&2
        exit 1
    fi

    step "Installing the virtual screen and the browser viewer"
    sudo apt-get update
    sudo apt-get install -y xvfb x11vnc novnc websockify

    step "Installing the preview service"
    sudo install -m 755 "$repo/display/deploy/preview-run.sh" /usr/local/bin/homeos-preview
    sed "s/@USER@/$user/" "$repo/display/deploy/homeos-preview.service" \
        | sudo tee /etc/systemd/system/homeos-preview.service >/dev/null
    sudo mkdir -p /etc/homeos

    if [ "$lan" = 1 ]; then
        step "Setting the preview password"
        echo "Pick a password for the browser page (VNC uses only the first 8 characters)."
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        x11vnc -storepasswd "$tmp"
        sudo install -m 600 -o "$user" -g "$user" "$tmp" /etc/homeos/preview.passwd
        echo "HOMEOS_PREVIEW_LAN=1" | sudo tee /etc/homeos/preview.env >/dev/null
    else
        sudo rm -f /etc/homeos/preview.env
    fi

    # The kiosk needs the panel; without one it would just keep restarting.
    # Disable it so both are not wanted by multi-user.target. Each conflicts
    # with the other, and a boot with both enabled can drop both.
    sudo systemctl daemon-reload
    sudo systemctl disable --now homeos-display 2>/dev/null || true
    sudo systemctl unmask homeos-preview 2>/dev/null || true
    if ! sudo systemctl enable --now homeos-preview; then
        echo "Preview did not stay up on the first start. It stays enabled and will keep retrying." >&2
    fi
    if ! sudo systemctl restart homeos-preview; then
        echo "Preview did not stay up yet. It will keep retrying." >&2
    fi

    step "Preview is running"
    if [ "$lan" = 1 ]; then
        echo "On a computer on the same network, open:"
        echo "    http://$host:$web_port/$url_path"
        echo "and enter the password you just set."
    else
        echo "On your computer, open a tunnel (keep this terminal open):"
        echo "    ssh -L $web_port:localhost:$web_port $user@$host"
        echo "Then open this in your browser:"
        echo "    http://localhost:$web_port/$url_path"
    fi
    echo
    echo "The mouse works as touch. When the panel is connected: ./display/deploy/preview.sh off"
    ;;
off)
    sudo systemctl disable --now homeos-preview 2>/dev/null || true
    sudo rm -f /etc/homeos/preview.env /etc/homeos/preview.passwd
    sudo systemctl unmask homeos-display 2>/dev/null || true
    # Same as install-pi.sh: keep the login prompt off the panel.
    sudo systemctl mask getty@tty1.service autovt@tty1.service 2>/dev/null || true
    if ! sudo systemctl enable --now homeos-display; then
        echo "homeos-display did not stay up on the first start. It stays enabled and will keep retrying." >&2
    fi
    if ! sudo systemctl restart homeos-display; then
        echo "homeos-display did not stay up yet. It will keep retrying." >&2
    fi
    echo "Preview is off; Ohana runs on the panel again."
    ;;
status)
    systemctl --no-pager status homeos-preview homeos-display || true
    ;;
*)
    usage
    ;;
esac

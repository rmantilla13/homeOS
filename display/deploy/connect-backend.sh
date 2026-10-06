#!/usr/bin/env bash
# Connects this display to your Supabase project. It asks for the project URL
# and the publishable key, checks them with Supabase, saves them in
# /etc/homeos/display.env and restarts homeOS (the kiosk, or preview mode).
#
#   ./display/deploy/connect-backend.sh
#
# The display then shows a 6-digit code; pair it from the iOS app
# (Family -> Pair a display).
set -euo pipefail

if [ "$(uname -s)" != Linux ]; then
    echo "This runs on the Raspberry Pi. Log in to it first (ssh <user>@homeos.local)." >&2
    exit 1
fi

env_file=/etc/homeos/display.env

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user; it uses sudo where needed." >&2
    exit 1
fi
if [ ! -f "$env_file" ]; then
    echo "$env_file is missing. Run ./display/deploy/install-pi.sh first." >&2
    exit 1
fi

echo "Both values are in the Supabase dashboard: Project Settings -> API Keys."
read -rp "Project URL (https://<project-id>.supabase.co): " url
read -rp "Publishable key (sb_publishable_...): " key
# Pasting often brings along spaces, a trailing slash or quotes.
url="$(printf '%s' "$url" | tr -d '[:space:]"'"'")"
url="${url%/}"
key="$(printf '%s' "$key" | tr -d '[:space:]"'"'")"

case "$url" in
    https://*.supabase.co) ;;
    *) echo "That URL should look like https://<project-id>.supabase.co" >&2; exit 1 ;;
esac
case "$key" in
    sb_publishable_*) ;;
    sb_secret_*)
        echo "That's the secret key. Never put it on a device; use the publishable key." >&2
        exit 1 ;;
    eyJ*)
        # A legacy JWT key: the anon one is fine, the service_role one is not.
        payload="$(printf '%s' "$key" | cut -d. -f2 | tr '_-' '/+')"
        while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
        if printf '%s' "$payload" | base64 -d 2>/dev/null | grep -q '"role" *: *"service_role"'; then
            echo "That's the service_role key. Never put it on a device; use the anon or publishable key." >&2
            exit 1
        fi ;;
    *) echo "That doesn't look like a Supabase key (sb_publishable_... or eyJ...)." >&2; exit 1 ;;
esac

echo "Checking with Supabase..."
code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "apikey: $key" "$url/auth/v1/settings" || true)"
case "$code" in
    200) echo "OK: the project answered and accepted the key." ;;
    000) echo "Couldn't reach $url. Check the URL and the Pi's internet connection." >&2; exit 1 ;;
    401|403) echo "Supabase rejected that key (HTTP $code). Copy the publishable key again." >&2; exit 1 ;;
    *) echo "Unexpected answer from Supabase (HTTP $code). Check the URL." >&2; exit 1 ;;
esac

# Replace any earlier (or commented-out) values, then add the new ones.
sudo sed -i -e '/^#\{0,1\}HOMEOS_SUPABASE_URL=/d' -e '/^#\{0,1\}HOMEOS_SUPABASE_ANON_KEY=/d' "$env_file"
printf 'HOMEOS_SUPABASE_URL=%s\nHOMEOS_SUPABASE_ANON_KEY=%s\n' "$url" "$key" | sudo tee -a "$env_file" >/dev/null
echo "Saved to $env_file"

service=homeos-display
if systemctl is-enabled --quiet homeos-preview 2>/dev/null; then
    service=homeos-preview
fi
sudo systemctl restart "$service"
echo "Restarted $service. Waiting for it to start..."
sleep 8
journalctl -u "$service" -n 15 --no-pager -o cat || true
echo
echo "The screen (or the browser preview) should now show a 6-digit pairing code."

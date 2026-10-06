#!/usr/bin/env bash
# Stops a TestFlight archive that would ship a placeholder or a secret.
# Reads build settings from the environment: Xcode's "Check Release Config"
# build phase (archives only) and archive-for-testflight.sh both call it.
#   SUPABASE_URL, SUPABASE_ANON_KEY, MEDIA_API_URL,
#   DEVELOPMENT_TEAM (or OHANAOS_TEAM_ID),
#   PRODUCT_BUNDLE_IDENTIFIER (or OHANAOS_BUNDLE_ID)
# Bash 3.2 compatible (the macOS /bin/bash).
set -u

failed=0
fail() {
  # "error:" makes Xcode show the line as a build error.
  echo "error: $*" >&2
  failed=1
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

url="${SUPABASE_URL:-}"
anon="${SUPABASE_ANON_KEY:-}"
media="${MEDIA_API_URL:-}"
team="${DEVELOPMENT_TEAM:-${OHANAOS_TEAM_ID:-}}"
bundle="${PRODUCT_BUNDLE_IDENTIFIER:-${OHANAOS_BUNDLE_ID:-}}"

# Supabase project URL.
if [[ -z "$url" ]]; then
  fail "SUPABASE_URL is empty. Set it in ios/Config/Local.xcconfig as https:/\$()/<project>.supabase.co"
elif [[ "$url" != https://?* ]]; then
  fail "SUPABASE_URL must start with https:// (write https:/\$()/ in the xcconfig), got: $url"
elif [[ "$(lower "$url")" == *your-project* || "$url" == *'$('* ]]; then
  fail "SUPABASE_URL is still a placeholder: $url"
fi

# Anon (publishable) key. It ships in the app by design; a service-role or
# secret key must never.
if [[ -z "$anon" || "$anon" == YOUR-ANON-KEY || "$anon" == *'$('* ]]; then
  fail "SUPABASE_ANON_KEY is empty or a placeholder. Use the project's anon/publishable key."
elif [[ "$anon" == sb_secret_* ]]; then
  fail "SUPABASE_ANON_KEY is a secret key (sb_secret_...). Use the anon/publishable key."
elif [[ "$anon" == eyJ*.*.* ]]; then
  payload="$(printf '%s' "$anon" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in
    2) payload="$payload==" ;;
    3) payload="$payload=" ;;
  esac
  claims="$(printf '%s' "$payload" | base64 --decode 2>/dev/null || true)"
  if [[ "$claims" == *service_role* ]]; then
    fail "SUPABASE_ANON_KEY is the service_role key. Use the anon key."
  fi
fi

# Admin app origin for photo and video uploads. The app appends /api/media/*.
media_rest="${media#https://}"
if [[ -z "$media" ]]; then
  fail "MEDIA_API_URL is empty. The default is https://ohanaos.co; remove the empty MEDIA_API_URL line from Local.xcconfig."
elif [[ "$media" != https://?* ]]; then
  fail "MEDIA_API_URL must start with https:// (write https:/\$()/ in the xcconfig), got: $media"
elif [[ "$(lower "$media")" == *your-admin-app* || "$media" == *'$('* ]]; then
  fail "MEDIA_API_URL is still a placeholder: $media. Delete that line from Local.xcconfig to use https://ohanaos.co."
elif [[ "${media_rest%/}" == */* ]]; then
  fail "MEDIA_API_URL must be an origin with no path (the app adds /api/media/...), got: $media"
fi

if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  fail "The team id must be a 10-character Team ID (OHANAOS_TEAM_ID), got: ${team:-<empty>}"
fi
if [[ ! "$bundle" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  fail "The bundle id (OHANAOS_BUNDLE_ID) is not a reverse-DNS id: ${bundle:-<empty>}"
fi

exit "$failed"

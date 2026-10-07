#!/usr/bin/env bash
# Archive a Release build of OhanaOS.xcodeproj and export it for App Store
# Connect. With --upload, the export step uploads the build to App Store
# Connect (TestFlight) instead of writing an IPA.
#
#   ios/scripts/archive-for-testflight.sh            # IPA in ios/build/export
#   ios/scripts/archive-for-testflight.sh --upload   # straight to TestFlight
#   OHANA_BUILD_NUMBER=7 ios/scripts/archive-for-testflight.sh
#
# Needs a Mac with Xcode 26 or newer, signed in (Xcode > Settings > Accounts)
# with an Apple ID on the team, and ios/Config/Local.xcconfig filled in.
# With no Apple ID signed in (CI), set ASC_KEY_PATH (the .p8 file), ASC_KEY_ID
# and ASC_ISSUER_ID to sign in with an App Store Connect API key instead.
# The archive is then ad hoc signed and needs no development certificate.
# The export signs it with the cloud-managed Apple Distribution certificate.
# Bash 3.2 compatible (the macOS /bin/bash).
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
upload=0
case "${1:-}" in
  "") ;;
  --upload) upload=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# App Store Connect API key: all three variables or none.
auth=()
api_key=0
# Signed in with an Apple ID, Xcode signs the archive for development and may
# create or update certificates and profiles.
archive_signing=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  missing=""
  [[ -n "${ASC_KEY_PATH:-}" ]] || missing="$missing ASC_KEY_PATH"
  [[ -n "${ASC_KEY_ID:-}" ]] || missing="$missing ASC_KEY_ID"
  [[ -n "${ASC_ISSUER_ID:-}" ]] || missing="$missing ASC_ISSUER_ID"
  if [[ -n "$missing" ]]; then
    echo "An App Store Connect API key needs ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID together. Missing:$missing" >&2
    exit 1
  fi
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "ASC_KEY_PATH is not a file: $ASC_KEY_PATH" >&2
    exit 1
  fi
  # The script changes directory below, so make the path absolute.
  key_path="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
  auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  # Ad hoc signed, with the same settings Xcode Cloud uses. The key is used
  # only by the export. Without -allowProvisioningUpdates the archive never
  # contacts the developer website, so it can't create a development
  # certificate or need a registered device.
  archive_signing=(CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES)
  api_key=1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
local_cfg="$root/Config/Local.xcconfig"
defaults="$root/Config/Defaults.xcconfig"
archive="$root/build/Ohana.xcarchive"
export_dir="$root/build/export"

if [[ ! -f "$local_cfg" ]]; then
  echo "Copy ios/Config/Local.xcconfig.example to ios/Config/Local.xcconfig and set SUPABASE_URL and SUPABASE_ANON_KEY." >&2
  exit 1
fi

# The last assignment of a key in Defaults.xcconfig, then Local.xcconfig, read
# the way Xcode does: // starts a comment and $() expands to nothing.
setting() {
  local key="$1" file line value=""
  for file in "$defaults" "$local_cfg"; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%//*}"
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=(.*)$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
    done < "$file"
  done
  printf '%s' "$value" | sed -e 's/\$()//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

if grep -Eq '^[[:space:]]*HOMEOS_(TEAM_ID|BUNDLE_ID)' "$local_cfg"; then
  echo "warning: Local.xcconfig sets HOMEOS_TEAM_ID or HOMEOS_BUNDLE_ID. Those names are no longer read; use OHANAOS_TEAM_ID and OHANAOS_BUNDLE_ID." >&2
fi

team="$(setting OHANAOS_TEAM_ID)"
bundle="$(setting OHANAOS_BUNDLE_ID)"
supabase_url="$(setting SUPABASE_URL)"
media_url="$(setting MEDIA_API_URL)"

# Fail before a long archive if a value is missing or still a placeholder.
SUPABASE_URL="$supabase_url" SUPABASE_ANON_KEY="$(setting SUPABASE_ANON_KEY)" \
  MEDIA_API_URL="$media_url" DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$bundle" \
  bash "$root/scripts/check-release-config.sh"

# Every upload needs a new build number for the same version. Default: the UTC
# time as YYYYMMDD.HHMM, which only goes up (leading zeros dropped).
if [[ -n "${OHANA_BUILD_NUMBER:-}" ]]; then
  build="$OHANA_BUILD_NUMBER"
else
  stamp="$(date -u +%Y%m%d%H%M)"
  build="${stamp:0:8}.$((10#${stamp:8:4}))"
fi
if [[ ! "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "OHANA_BUILD_NUMBER must be one to three dot-separated integers, got: $build" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null; then
  echo "Archive from a Mac with Xcode 26 or newer." >&2
  exit 1
fi
xcode_major="$(xcodebuild -version | awk 'NR==1 { split($2, v, "."); print v[1] }')"
if [[ "$xcode_major" -lt 26 ]]; then
  echo "App Store Connect needs a build made with Xcode 26 or newer (iOS 26 SDK). Found Xcode $xcode_major." >&2
  exit 1
fi

echo "Archiving $bundle (team $team), build $build"
echo "  Supabase:  $supabase_url"
echo "  Media API: $media_url"
if [[ "$api_key" == 1 ]]; then
  echo "  Signing in with an App Store Connect API key"
  echo "  Archive: ad hoc signed. Export: cloud-managed Apple Distribution certificate."
fi

rm -rf "$archive" "$export_dir"
# With an API key there is no development certificate on this machine. Archive
# ad hoc signed, as Xcode Cloud does; the export signs with the cloud-managed
# Apple Distribution certificate.
xcodebuild \
  -project OhanaOS.xcodeproj \
  -scheme OhanaOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  ${archive_signing[@]+"${archive_signing[@]}"} \
  CURRENT_PROJECT_VERSION="$build" \
  archive

# Check what actually went into the archive.
app="$archive/Products/Applications/Ohana.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist"; }
if [[ "$(plist CFBundleIdentifier)" != "$bundle" || "$(plist CFBundleVersion)" != "$build" ]]; then
  echo "The archive has $(plist CFBundleIdentifier) build $(plist CFBundleVersion), expected $bundle build $build." >&2
  exit 1
fi
if [[ ! -f "$app/PrivacyInfo.xcprivacy" ]]; then
  echo "The archive is missing PrivacyInfo.xcprivacy." >&2
  exit 1
fi
SUPABASE_URL="$(plist SupabaseURL)" SUPABASE_ANON_KEY="$(plist SupabaseAnonKey)" \
  MEDIA_API_URL="$(plist MediaAPIURL)" DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$(plist CFBundleIdentifier)" \
  bash "$root/scripts/check-release-config.sh"

# ExportOptions.plist with this team, and destination "upload" for --upload.
# The export always signs for App Store Connect. With an API key, Xcode uses
# the cloud-managed Apple Distribution certificate.
options="$root/build/ExportOptions.plist"
cp "$root/Config/ExportOptions.plist" "$options"
/usr/libexec/PlistBuddy -c "Set :teamID $team" "$options"
if [[ "$upload" == 1 ]]; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$options"
fi

xcodebuild \
  -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$options" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"}

version="$(plist CFBundleShortVersionString)"
if [[ "$upload" == 1 ]]; then
  echo "Uploaded $version ($build). It shows in App Store Connect > TestFlight once processing finishes."
else
  echo "IPA for $version ($build) is in ios/build/export."
  echo "Upload it with the Transporter app, or rerun with --upload."
fi

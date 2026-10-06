#!/usr/bin/env bash
# Archive a Release build and export an App Store Connect IPA.
# Requires Xcode 16 and a filled-in ios/Config/Local.xcconfig.
# Open the checked-in HomeOS.xcodeproj. Sign in to Xcode with the Apple ID
# on team 92X9CP6C6D before running this.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
local_cfg="$root/Config/Local.xcconfig"
defaults="$root/Config/Defaults.xcconfig"

if [[ ! -f "$local_cfg" ]]; then
  echo "Copy ios/Config/Local.xcconfig.example to ios/Config/Local.xcconfig and set the Supabase URL and anon key." >&2
  exit 1
fi

value() {
  # Defaults, then Local.xcconfig. The last assignment wins.
  sed -n "s/^$1 = \\(.*\\)$/\\1/p" "$defaults" "$local_cfg" | tail -n 1
}

team="$(value HOMEOS_TEAM_ID)"
url="$(value SUPABASE_URL)"
anon="$(value SUPABASE_ANON_KEY)"

if [[ "$team" == YOURTEAMID || ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Set HOMEOS_TEAM_ID in ios/Config/Local.xcconfig to your 10-character Team ID." >&2
  exit 1
fi
if [[ -z "$url" || "$url" == *YOUR-PROJECT* ]]; then
  echo "Set SUPABASE_URL in ios/Config/Local.xcconfig (https:/\$()/your-project.supabase.co)." >&2
  exit 1
fi
if [[ -z "$anon" || "$anon" == YOUR-ANON-KEY ]]; then
  echo "Set SUPABASE_ANON_KEY in ios/Config/Local.xcconfig." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null; then
  echo "Archive from a Mac with Xcode 16 or newer." >&2
  exit 1
fi

rm -rf "$root/build/HomeOS.xcarchive" "$root/build/export"
xcodebuild \
  -project HomeOS.xcodeproj \
  -scheme HomeOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$root/build/HomeOS.xcarchive" \
  -allowProvisioningUpdates \
  archive
xcodebuild \
  -exportArchive \
  -archivePath "$root/build/HomeOS.xcarchive" \
  -exportPath "$root/build/export" \
  -exportOptionsPlist "$root/Config/ExportOptions.plist" \
  -allowProvisioningUpdates

echo "IPA is in ios/build/export. Upload it with Xcode Organizer or the Transporter app."
echo "Each upload needs a new CURRENT_PROJECT_VERSION in ios/HomeOS.xcodeproj/project.pbxproj."

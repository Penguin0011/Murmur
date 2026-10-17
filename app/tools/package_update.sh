#!/bin/zsh
# Prepare assets only. Publishing a GitHub Release is a separate, explicit action.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
app_path="${1:-$project_root/runtime/Murmur.app}"
output="${2:-$project_root/runtime/update}"
sparkle_path="$("$project_root/app/tools/fetch_sparkle.sh" | tail -1)"
plist="$app_path/Contents/Info.plist"
feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist")"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" >/dev/null
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
# Use the exact version tag in archive links; the appcast alone follows latest.
repository="${feed%/releases/latest/download/appcast.xml}"
[[ "$repository" != "$feed" && "$repository" == https://github.com/*/* ]] || { echo 'Invalid GitHub update feed.' >&2; exit 1; }
codesign --verify --deep --strict "$app_path"
[[ ! -e "$output" ]] || { echo 'Choose a fresh output folder for each release.' >&2; exit 1; }
mkdir -p "$output"
archive="$output/Murmur-$version.zip"
ditto -c -k --keepParent "$app_path" "$archive"
key_args=(--account "${MURMUR_SPARKLE_KEY_ACCOUNT:-Murmur}")
if [[ -n "${MURMUR_SPARKLE_KEY_FILE:-}" ]]; then key_args=(--ed-key-file "$MURMUR_SPARKLE_KEY_FILE"); fi
args=(--download-url-prefix "$repository/releases/download/v$version/" --maximum-deltas 0 --embed-release-notes)
if [[ -n "${MURMUR_RELEASE_NOTES:-}" ]]; then cp "$MURMUR_RELEASE_NOTES" "$output/Murmur-$version.md"; fi
"$sparkle_path/bin/generate_appcast" "${args[@]}" "${key_args[@]}" "$output"
# generate_appcast checks the embedded key; explicitly verify the signature too.
signature="$(python3 - "$output/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
signature = root.find('./channel/item/enclosure').attrib.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
if not signature:
    raise SystemExit('No signed archive in appcast: check that the signing key matches SUPublicEDKey.')
print(signature)
PY
)"
"$sparkle_path/bin/sign_update" "${key_args[@]}" --verify "$archive" "$signature"
echo "Upload $archive and $output/appcast.xml to a draft release tagged v$version, then publish it as latest."

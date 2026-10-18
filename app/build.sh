#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# The Command Line Tools' macOS 27 SDK needs a SwiftUI macro plugin they do not ship; use their
# macOS 26 SDK when it is installed. Set SDKROOT to choose another SDK.
sdk26="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk"
if [[ -z "${SDKROOT:-}" && -d "$sdk26" ]]; then export SDKROOT="$sdk26"; fi
app_path="$project_root/runtime/Murmur.app"
sparkle_path="$("$project_root/app/tools/fetch_sparkle.sh" | tail -1)"
runner_path="$project_root/module-one/models/Runner/.build/release/ModelBench"
identity="${MURMUR_SIGN_IDENTITY:-clouddev Development}"
signing_flags=(--options runtime --timestamp=none)
if [[ "${MURMUR_RELEASE:-0}" == 1 ]]; then
  [[ "$identity" == "Developer ID Application:"* && -n "${MURMUR_NOTARY_PROFILE:-}" ]] || { echo "Release builds require a Developer ID Application identity and MURMUR_NOTARY_PROFILE." >&2; exit 1; }
  security find-identity -v -p codesigning | grep -Fq "\"$identity\"" || { echo "The release signing identity is unavailable." >&2; exit 1; }
  signing_flags=(--options runtime --timestamp)
else
  security find-identity -p codesigning | grep -Fq "\"$identity\"" || identity=-
fi
# Always build: it is incremental, and a stale helper would reject newer arguments (--ctc).
swift build --package-path "$project_root/module-one/models/Runner" -c release
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# -O: the model downloader verifies ~1.8 GB with pure-Swift SHA-256/SHA-1 (about 4x faster optimized).
# No assert() runs in the app (only spike test helpers it never calls use it), so -O drops no checks;
# precondition, overflow traps and exclusivity checks stay on. check_ui.sh and the checks stay unoptimized.
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  "$project_root/spike/Shortcut.swift" "$project_root/spike/Insertion.swift" "$project_root/spike/Observation.swift" \
  "$project_root/module-one/capture/Capture.swift" "$project_root/module-one/session/Session.swift" \
  "$project_root/app/History.swift" "$project_root/app/Insights.swift" "$project_root/app/Controller.swift" \
  "$project_root/app/Cleanup.swift" "$project_root/app/Dictionary.swift" "$project_root/app/Learning.swift" \
  "$project_root/app/Retention.swift" "$project_root/app/Providers.swift" "$project_root/app/Credentials.swift" \
  "$project_root/app/Processing.swift" "$project_root/app/ModelDownload.swift" "$project_root/app/Updates.swift" "$project_root/app/AppUpdater.swift" \
  "$project_root/app/AppServices.swift" "$project_root/app/Routes.swift" "$project_root/app/AppleCleanup.swift" \
  "$project_root/app/UI.swift" "$project_root/app/Meetings.swift" "$project_root/app/MeetingNotes.swift" "$project_root/app/MeetingSpeakers.swift" "$project_root/app/MeetingCapture.swift" "$project_root/app/MeetingRecorder.swift" "$project_root/app/MeetingsUI.swift" "$project_root/app/LaunchOptions.swift" "$project_root/app/main.swift" \
  "$project_root/app/CallDetection.swift" "$project_root/app/CallOfferUI.swift" \
  -F "$sparkle_path" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app_path/Contents/MacOS/Murmur"
cp -R "$project_root/app/Fonts" "$app_path/Contents/Resources/"
cp -R "$project_root/app/Licenses" "$app_path/Contents/Resources/"
cp "$project_root/LICENSE" "$project_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/"
cp "$project_root/app/Info.plist" "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Frameworks"
rm -rf "$app_path/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_path/Sparkle.framework" "$app_path/Contents/Frameworks/Sparkle.framework"
python3 "$project_root/app/tools/configure_updates.py" "$app_path/Contents/Info.plist"
cp "$sparkle_path/LICENSE" "$app_path/Contents/Resources/Sparkle-LICENSE"

cp "$runner_path" "$app_path/Contents/MacOS/ModelBench"
cp "$project_root/app/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$project_root/module-one/models/artifact-pins.json" "$app_path/Contents/Resources/artifact-pins.json"
if [[ -d "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" ]]; then
  rm -rf "$app_path/Contents/Resources/FluidAudio_FluidAudio.bundle"
  cp -R "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" "$app_path/Contents/Resources/"
fi
# Sign nested Sparkle code from the inside out, preserving its helper entitlements.
framework="$app_path/Contents/Frameworks/Sparkle.framework"
for nested in "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
  codesign --force --sign "$identity" "${signing_flags[@]}" --preserve-metadata=entitlements "$nested"
done
entitlements="$project_root/app/Murmur.entitlements"
if [[ "${MURMUR_RELEASE:-0}" != 1 ]]; then
  # Local/self-signed identities cannot satisfy Apple's library validation for Sparkle.
  entitlements="$project_root/runtime/Murmur-development.entitlements"
  cp "$project_root/app/Murmur.entitlements" "$entitlements"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
# A stable identity keeps macOS privacy permissions across rebuilds; ad-hoc signing loses them every build.
codesign --force --sign "$identity" "${signing_flags[@]}" "$app_path/Contents/MacOS/ModelBench"
codesign --force --sign "$identity" "${signing_flags[@]}" --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
if [[ "${MURMUR_RELEASE:-0}" == 1 ]]; then
  archive="$project_root/runtime/Murmur-notarization.zip"
  ditto -c -k --keepParent "$app_path" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$MURMUR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl --assess --type execute "$app_path"
fi
echo "$app_path"

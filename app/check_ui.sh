#!/bin/zsh
# Builds and runs only the isolated synthetic UI fixture.
set -eu
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# The Command Line Tools' macOS 27 SDK needs a SwiftUI macro plugin they do not ship; use their
# macOS 26 SDK when it is installed. Set SDKROOT to choose another SDK.
sdk26="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk"
if [[ -z "${SDKROOT:-}" && -d "$sdk26" ]]; then export SDKROOT="$sdk26"; fi
fixture_path="$project_root/runtime/UIQA.app"
mkdir -p "$fixture_path/Contents/MacOS"
swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  "$project_root/spike/Shortcut.swift" "$project_root/spike/Insertion.swift" "$project_root/spike/Observation.swift" \
  "$project_root/module-one/capture/Capture.swift" "$project_root/module-one/session/Session.swift" \
  "$project_root/app/History.swift" "$project_root/app/Controller.swift" \
  "$project_root/app/Cleanup.swift" "$project_root/app/Dictionary.swift" "$project_root/app/Learning.swift" \
  "$project_root/app/Retention.swift" "$project_root/app/Providers.swift" "$project_root/app/Credentials.swift" \
  "$project_root/app/Processing.swift" "$project_root/app/ModelDownload.swift" "$project_root/app/Updates.swift" \
  "$project_root/app/AppServices.swift" "$project_root/app/Routes.swift" "$project_root/app/AppleCleanup.swift" \
  "$project_root/app/UI.swift" "$project_root/app/check_ui.swift" \
  -o "$fixture_path/Contents/MacOS/UIQA"
cp "$project_root/app/Info.plist" "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UIQA' "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cc.clouddev.dictation.uiqa' "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Murmur UI Check' "$fixture_path/Contents/Info.plist"
codesign --force --sign - "$fixture_path"
exec "$fixture_path/Contents/MacOS/UIQA" "$@"

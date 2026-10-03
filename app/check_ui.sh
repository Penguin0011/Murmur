#!/bin/zsh
# Builds and runs only the isolated synthetic UI fixture.
set -eu
project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_path="$project_root/runtime/UIQA.app"
mkdir -p "$fixture_path/Contents/MacOS"
swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  "$project_root/spike/Shortcut.swift" "$project_root/spike/Insertion.swift" \
  "$project_root/module-one/capture/Capture.swift" "$project_root/module-one/session/Session.swift" \
  "$project_root/app/History.swift" "$project_root/app/Controller.swift" \
  "$project_root/app/UI.swift" "$project_root/app/check_ui.swift" \
  -o "$fixture_path/Contents/MacOS/UIQA"
cp "$project_root/app/Info.plist" "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UIQA' "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cc.clouddev.dictation.uiqa' "$fixture_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Murmur UI Check' "$fixture_path/Contents/Info.plist"
codesign --force --sign - "$fixture_path"
exec "$fixture_path/Contents/MacOS/UIQA" "$@"

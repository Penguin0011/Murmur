#!/bin/zsh
set -eu
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/runtime/Murmur.app"
runner_path="$project_root/module-one/models/Runner/.build/release/ModelBench"
# Always build: it is incremental, and a stale helper would reject newer arguments (--ctc).
swift build --package-path "$project_root/module-one/models/Runner" -c release
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# -O: the model downloader verifies ~1.8 GB with pure-Swift SHA-256/SHA-1 (about 4x faster optimized).
# No assert() runs in the app (only spike test helpers it never calls use it), so -O drops no checks;
# precondition, overflow traps and exclusivity checks stay on. check_ui.sh and the checks stay unoptimized.
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  "$project_root/spike/Shortcut.swift" "$project_root/spike/Insertion.swift" \
  "$project_root/module-one/capture/Capture.swift" "$project_root/module-one/session/Session.swift" \
  "$project_root/app/History.swift" "$project_root/app/Controller.swift" \
  "$project_root/app/Cleanup.swift" "$project_root/app/Dictionary.swift" "$project_root/app/Learning.swift" \
  "$project_root/app/Retention.swift" "$project_root/app/Providers.swift" "$project_root/app/Credentials.swift" \
  "$project_root/app/Processing.swift" "$project_root/app/ModelDownload.swift" "$project_root/app/Updates.swift" \
  "$project_root/app/AppServices.swift" "$project_root/app/Routes.swift" \
  "$project_root/app/UI.swift" "$project_root/app/LaunchOptions.swift" "$project_root/app/main.swift" \
  -o "$app_path/Contents/MacOS/Murmur"
cp "$project_root/app/Info.plist" "$app_path/Contents/Info.plist"
cp "$runner_path" "$app_path/Contents/MacOS/ModelBench"
cp "$project_root/module-one/models/artifact-pins.json" "$app_path/Contents/Resources/artifact-pins.json"
if [[ -d "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" ]]; then
  rm -rf "$app_path/Contents/Resources/FluidAudio_FluidAudio.bundle"
  cp -R "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" "$app_path/Contents/Resources/"
fi
# A stable identity keeps macOS privacy permissions across rebuilds; ad-hoc signing loses them every build.
identity="${MURMUR_SIGN_IDENTITY:-clouddev Development}"
security find-identity -p codesigning | grep -q "\"$identity\"" || identity=-
codesign --force --sign "$identity" "$app_path/Contents/MacOS/ModelBench"
codesign --force --sign "$identity" "$app_path"
echo "$app_path"

#!/bin/zsh
set -eu
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_root/runtime/Dictation.app"
runner_path="$project_root/module-one/models/Runner/.build/release/ModelBench"
if [[ ! -x "$runner_path" ]]; then
  swift build --package-path "$project_root/module-one/models/Runner" -c release
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
swiftc -swift-version 5 -target arm64-apple-macos26.0 \
  "$project_root/spike/Shortcut.swift" "$project_root/spike/Insertion.swift" \
  "$project_root/module-one/capture/Capture.swift" "$project_root/module-one/session/Session.swift" \
  "$project_root/app/History.swift" "$project_root/app/Controller.swift" \
  "$project_root/app/UI.swift" "$project_root/app/main.swift" \
  -o "$app_path/Contents/MacOS/Dictation"
cp "$project_root/app/Info.plist" "$app_path/Contents/Info.plist"
cp "$runner_path" "$app_path/Contents/MacOS/ModelBench"
cp "$project_root/module-one/models/artifact-pins.json" "$app_path/Contents/Resources/artifact-pins.json"
if [[ -d "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" ]]; then
  cp -R "$project_root/module-one/models/Runner/.build/release/FluidAudio_FluidAudio.bundle" "$app_path/Contents/Resources/"
fi
codesign --force --sign - "$app_path/Contents/MacOS/ModelBench"
codesign --force --sign - "$app_path"
echo "$app_path"

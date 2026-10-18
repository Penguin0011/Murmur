#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
destination="$project_root/runtime/Sparkle-2.10.0"
if [[ ! -f "$destination/.verified" ]]; then
  mkdir -p "$destination"
  archive="$destination/distribution.tar.xz"
  curl --fail --location --retry 3 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz' -o "$archive"
  echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $archive" | shasum -a 256 -c -
  tar -xJf "$archive" -C "$destination"
  touch "$destination/.verified"
fi
print -r -- "$destination"

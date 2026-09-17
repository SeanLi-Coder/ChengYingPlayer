#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-chrome-interaction.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  "$project_root/iina/PlaySlider.swift"
  "$project_root/iina/VolumeSlider.swift"
  "$project_root/iina/PlaySliderLoopKnob.swift"
  "$project_root/Tools/PlayerChromeInteractionTests/Boundary.swift"
  "$project_root/Tools/PlayerChromeInteractionTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos12 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/PlayerChromeInteractionTests" "${sources[@]}"
"$test_dir/PlayerChromeInteractionTests"

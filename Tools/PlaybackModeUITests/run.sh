#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-mode-ui.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/PlaybackModeUITests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/PlaybackModeUITests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/Localizable.strings" "$test_bundle/Resources/$language.lproj/"
  cp "$project_root/iina/$language.lproj/PrefGeneralViewController.strings" "$test_bundle/Resources/$language.lproj/"
done
xcrun swift "$project_root/Tools/PlaybackModeUITests/extract.swift" "$project_root" "$test_dir"
test_sources=(
  "$project_root/iina/PlaylistPlaybackPolicy.swift"
  "$test_dir/Production.swift"
  "$project_root/Tools/PlaybackModeUITests/Boundary.swift"
  "$project_root/Tools/PlaybackModeUITests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${test_sources[@]}"
xcrun swiftc -o "$test_bundle/MacOS/PlaybackModeUITests" "${test_sources[@]}"
for language in en zh-Hans zh-Hant; do
  "$test_bundle/MacOS/PlaybackModeUITests" -AppleLanguages "($language)"
done

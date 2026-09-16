#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${VIDEO_VIEWPORT_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-video-viewport.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swift "$project_root/Tools/VideoViewportTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$source_root/iina/PlayerState.swift"
  "$source_root/iina/MPVOption.swift"
  "$source_root/iina/MPVProperty.swift"
  "$source_root/iina/VideoTools/VideoToolsShortcuts.swift"
  "$source_root/iina/VideoTools/VideoToolsLoopPolicy.swift"
  "$source_root/iina/VideoTools/VideoToolsPlayerBridge.swift"
  "$project_root/Tools/VideoViewportTests/Boundary.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/VideoViewportTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
test_bundle="$test_dir/VideoViewportTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$source_root/iina/$language.lproj/Localizable.strings" "$test_bundle/Resources/$language.lproj/"
done
xcrun swiftc -o "$test_bundle/MacOS/VideoViewportTests" "${sources[@]}"
for language in en zh-Hans; do
  "$test_bundle/MacOS/VideoViewportTests" -AppleLanguages "($language)"
done

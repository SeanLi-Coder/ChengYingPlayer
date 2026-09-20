#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${VIDEO_WINDOW_SIZING_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-window-sizing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swift "$project_root/Tools/VideoWindowSizingTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$source_root/iina/MPVOption.swift"
  "$source_root/iina/MPVProperty.swift"
  "$project_root/Tools/VideoWindowSizingTests/Boundary.swift"
  "$test_dir/Production.swift"
  "$project_root/Tools/VideoWindowSizingTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/VideoWindowSizingTests" "${sources[@]}"
"$test_dir/VideoWindowSizingTests"

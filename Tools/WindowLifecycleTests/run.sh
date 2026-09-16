#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${WINDOW_LIFECYCLE_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-window-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swift "$project_root/Tools/WindowLifecycleTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$source_root/iina/PlayerState.swift"
  "$test_dir/Controllers.swift"
  "$project_root/Tools/WindowLifecycleTests/Boundary.swift"
  "$project_root/Tools/WindowLifecycleTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/WindowLifecycleTests" "${sources[@]}"
"$test_dir/WindowLifecycleTests" "${1:-all}"

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-chrome-lifecycle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

xcrun swift "$project_root/Tools/PlayerChromeLifecycleTests/extract.swift" "$project_root" "$test_dir"
sources=(
  "$project_root/iina/PlayerState.swift"
  "$project_root/iina/PlayerChromePolicy.swift"
  "$project_root/Tools/PlayerChromeLifecycleTests/Fixture.swift"
  "$test_dir/Controller.swift"
  "$project_root/Tools/PlayerChromeLifecycleTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -sanitize=address -o "$test_dir/PlayerChromeLifecycleTests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/PlayerChromeLifecycleTests"

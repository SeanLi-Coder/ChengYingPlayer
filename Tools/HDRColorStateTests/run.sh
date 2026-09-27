#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${HDR_COLOR_STATE_SOURCE_ROOT:-$project_root}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-hdr-color-state.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
xcrun swift "$project_root/Tools/HDRColorStateTests/extract.swift" "$source_root" "$test_dir"
sources=(
  "$source_root/iina/MPVOption.swift"
  "$source_root/iina/PlayerState.swift"
  "$project_root/Tools/HDRColorStateTests/Boundary.swift"
  "$test_dir/Production.swift"
  "$project_root/Tools/HDRColorStateTests/main.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_dir/HDRColorStateTests" "${sources[@]}"
"$test_dir/HDRColorStateTests"

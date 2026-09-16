#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-visual-style.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -o "$test_dir/VisualStyleTests" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/Tools/VisualStyleTests/main.swift"
"$test_dir/VisualStyleTests"

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-simplification.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compile the real command policy; inspect production XIBs without controller doubles.
xcrun swiftc -o "$test_dir/SimplificationTests" \
  "$project_root/iina/IINACommand.swift" \
  "$project_root/Tools/SimplificationTests/main.swift"
xcrun swiftc -o "$test_dir/chengying-cli" \
  "$project_root/iina/Regex.swift" \
  "$project_root/iina-cli/main.swift"
# The real CLI requires a sibling executable even for help and argument validation.
ln -s /usr/bin/true "$test_dir/ChengYing"
"$test_dir/SimplificationTests" "$project_root" "$test_dir/chengying-cli"

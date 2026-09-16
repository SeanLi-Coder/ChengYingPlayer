#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-preference-search.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Widen test visibility only; compile the production implementation unchanged otherwise.
sed 's/^  private /  /' "$project_root/iina/PreferenceWindowController.swift" \
  > "$test_dir/PreferenceWindowController.swift"
xcrun swiftc -o "$test_dir/PreferenceSearchTests" \
  "$project_root/Tools/PreferenceSearchTests/Stubs.swift" \
  "$project_root/iina/PreferenceViewController.swift" \
  "$project_root/iina/CollapseView.swift" \
  "$test_dir/PreferenceWindowController.swift" \
  "$project_root/Tools/PreferenceSearchTests/main.swift"
"$test_dir/PreferenceSearchTests"

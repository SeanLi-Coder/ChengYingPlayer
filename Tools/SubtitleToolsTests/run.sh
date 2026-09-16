#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-subtitle-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/SubtitleControlsTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/SubtitleTools.strings" "$test_bundle/Resources/$language.lproj/"
done

# Compile the production AppKit controller, service, protocol models, and helper client.
xcrun swiftc -o "$test_bundle/MacOS/SubtitleControlsTests" \
  "$project_root/Tools/SubtitleToolsTests/Stubs.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsModels.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsHelperClient.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsService.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsViewController.swift" \
  "$project_root/Tools/SubtitleToolsTests/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/SubtitleControlsTests" -AppleLanguages "($language)"
done

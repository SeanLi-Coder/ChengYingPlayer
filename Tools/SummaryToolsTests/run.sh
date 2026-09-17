#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-summary-tools.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/SummaryToolsTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/SummaryToolsTests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/SummaryTools.strings" "$test_bundle/Resources/$language.lproj/"
  cp "$project_root/iina/$language.lproj/SubtitleTools.strings" "$test_bundle/Resources/$language.lproj/"
done
xcrun swiftc "$project_root/Tools/SummaryToolsTests/FakeHelper.swift" -o "$test_bundle/MacOS/FixtureHelper"
xcrun swiftc -o "$test_bundle/MacOS/SummaryToolsTests" \
  "$project_root/iina/Updates/UpdateWorkAdmission.swift" \
  "$project_root/Tools/SubtitleToolsTests/Stubs.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsModels.swift" \
  "$project_root/iina/SubtitleTools/SummaryToolsModels.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsHelperClient.swift" \
  "$project_root/iina/SubtitleTools/SubtitleToolsService.swift" \
  "$project_root/iina/SubtitleTools/SummaryToolsWindowController.swift" \
  "$project_root/Tools/SummaryToolsTests/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/SummaryToolsTests" -AppleLanguages "($language)"
done

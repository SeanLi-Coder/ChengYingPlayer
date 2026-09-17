#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-native-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/NativeControlsTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/Localizable.strings" "$test_bundle/Resources/$language.lproj/"
done

# Compile the actual AppKit controller and bridge against small playback doubles.
xcrun swiftc -o "$test_bundle/MacOS/NativeControlsTests" \
  "$project_root/Tools/VideoToolsTests/Stubs.swift" \
  "$project_root/iina/ChengYingStyle.swift" \
  "$project_root/iina/VideoTools/VideoToolsModels.swift" \
  "$project_root/iina/VideoTools/VideoToolsShortcuts.swift" \
  "$project_root/iina/VideoTools/VideoToolsLoopPolicy.swift" \
  "$project_root/iina/VideoTools/VideoToolsRotationCoordinator.swift" \
  "$project_root/iina/VideoTools/VideoToolsPlayerBridge.swift" \
  "$project_root/iina/VideoTools/VideoToolsViewController.swift" \
  "$project_root/Tools/VideoToolsTests/ShortcutTests.swift" \
  "$project_root/Tools/VideoToolsTests/LoopPolicyTests.swift" \
  "$project_root/Tools/VideoToolsTests/main.swift"
for language in en zh-Hans zh-Hant; do
  "$test_bundle/MacOS/NativeControlsTests" -AppleLanguages "($language)"
done

xcrun swiftc -o "$test_dir/RotationCoordinatorTests" \
  "$project_root/iina/VideoTools/VideoToolsModels.swift" \
  "$project_root/iina/VideoTools/VideoToolsRotationCoordinator.swift" \
  "$project_root/Tools/VideoToolsTests/RotationCoordinatorTests.swift"
"$test_dir/RotationCoordinatorTests"

xcrun swiftc -o "$test_bundle/MacOS/TaskManagerTests" \
  "$project_root/iina/VideoTools/VideoToolsModels.swift" \
  "$project_root/iina/VideoTools/VideoToolsRotationCoordinator.swift" \
  "$project_root/iina/VideoTools/VideoToolsTaskManager.swift" \
  "$project_root/Tools/VideoToolsTests/TaskManagerTests.swift"
"$test_bundle/MacOS/TaskManagerTests" -AppleLanguages '(en)'

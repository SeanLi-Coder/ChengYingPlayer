#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-download-center-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/DownloadCenterTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_bundle/Resources"
cp "$project_root/Tools/DownloadCenterTests/Info.plist" "$test_bundle/Info.plist"
for language in en zh-Hans; do
  mkdir -p "$test_bundle/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/DownloadCenter.strings" "$test_bundle/Resources/$language.lproj/"
done
test_python="$(xcrun --find python3)"
test_python_dir="$(dirname "$test_python")"
export PATH="$test_python_dir:$PATH"
sources=(
  "$project_root/iina/Updates/UpdateWorkAdmission.swift"
  "$project_root/iina/ChengYingStyle.swift"
  "$project_root/iina/ImageViewer/ImageFileSupport.swift"
  "$project_root/iina/DownloadCenter/DownloadCenterModels.swift"
  "$project_root/iina/DownloadCenter/DownloadCenterService.swift"
  "$project_root/iina/DownloadCenter/DownloadCenterWindowController.swift"
  "$project_root/Tools/DownloadCenterTests/Stubs.swift"
)
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "${sources[@]}"
xcrun swiftc -o "$test_bundle/MacOS/DownloadCenterTests" "${sources[@]}" \
  "$project_root/Tools/DownloadCenterTests/main.swift"
for language in en zh-Hans; do
  "$test_bundle/MacOS/DownloadCenterTests" "$project_root/Tools/DownloadCenterTests/helper_fixture.py" "$test_dir" -AppleLanguages "($language)"
done

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:?Set SPARKLE_FRAMEWORK_DIR to the Sparkle 2.10 macos-arm64_x86_64 artifact directory}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-app-updates.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
app_dir="$test_dir/AppUpdateTests.app"
snapshot_dir="${APP_UPDATE_SNAPSHOT_DIR:-$test_dir/snapshots}"
test_language="${APP_UPDATE_TEST_LANGUAGE:-en}"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$snapshot_dir"
cp "$project_root/Tools/AppUpdateTests/Info.plist" "$app_dir/Contents/Info.plist"
for language in en zh-Hans zh-Hant; do
  mkdir -p "$app_dir/Contents/Resources/$language.lproj"
  cp "$project_root/iina/$language.lproj/Updates.strings" "$app_dir/Contents/Resources/$language.lproj/Updates.strings"
  plutil -lint "$project_root/iina/$language.lproj/Updates.strings"
done

sources=(
  "$project_root/iina/Updates/UpdatePolicy.swift"
  "$project_root/iina/Updates/AppUpdateWindowController.swift"
  "$project_root/iina/Updates/AppUpdateUserDriver.swift"
  "$project_root/iina/Updates/AppUpdateCoordinator.swift"
)
xcrun swiftc -target arm64-apple-macos12 -F "$sparkle_framework_dir" -typecheck "${sources[@]}"
xcrun swiftc -target arm64-apple-macos12 -F "$sparkle_framework_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$sparkle_framework_dir" \
  -o "$app_dir/Contents/MacOS/AppUpdateTests" "${sources[@]}" "$project_root/Tools/AppUpdateTests/main.swift"
"$app_dir/Contents/MacOS/AppUpdateTests" "$snapshot_dir" -AppleLanguages "($test_language)" 2> >(tee "$test_dir/stderr.log" >&2)
if rg -q 'Unable to simultaneously satisfy constraints|Unsatisfiable constraints' "$test_dir/stderr.log"; then
  printf '%s\n' 'FAIL: Native update window emitted Auto Layout conflicts.' >&2
  exit 1
fi

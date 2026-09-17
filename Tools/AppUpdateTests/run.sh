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
# Extract the production property and action, rather than duplicating their annotations.
python3 -B - "$project_root" "$test_dir" <<'PY'
import re
import sys
from pathlib import Path

root, temporary = map(Path, sys.argv[1:])
source = (root / "iina/AppDelegate.swift").read_text()
start, end = "  // MARK: - Application Updates\n", "  // MARK: - App Delegate\n"
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit("Application update source section is missing or ambiguous.")
section = source.split(start, 1)[1].split(end, 1)[0]
if "lazy var updateCoordinator" not in section or "func checkForUpdates(" not in section:
    raise SystemExit("Application update property or menu action is missing.")
template = (root / "Tools/AppUpdateTests/AppDelegateIsolation.swift.in").read_text()
marker = "  // APP_UPDATE_SOURCE_SECTION"
if template.count(marker) != 1:
    raise SystemExit("AppDelegate isolation template marker is invalid.")
fixture = template.replace(marker, section.rstrip())
(temporary / "AppDelegateIsolation.swift").write_text(fixture)
# Prove this fixture detects the original regression, without changing production files.
negative_section, replacements = re.subn(
    r"@MainActor\s+(?=private\(set\) lazy var updateCoordinator)", "", section
)
if replacements != 1:
    raise SystemExit("Expected one explicit main-actor annotation on the updater property.")
(temporary / "AppDelegateIsolationNegative.swift").write_text(template.replace(marker, negative_section.rstrip()))
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -F "$sparkle_framework_dir" \
  -typecheck "${sources[@]}" "$test_dir/AppDelegateIsolation.swift"
if xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -F "$sparkle_framework_dir" \
    -typecheck "${sources[@]}" "$test_dir/AppDelegateIsolationNegative.swift" \
    > "$test_dir/isolation-negative.log" 2>&1; then
  printf '%s\n' 'FAIL: The AppDelegate fixture did not detect the missing main-actor annotation.' >&2
  exit 1
fi
if ! /usr/bin/grep -q 'error: call to main actor-isolated initializer' "$test_dir/isolation-negative.log"; then
  printf '%s\n' 'FAIL: The AppDelegate negative control failed for an unexpected reason.' >&2
  /usr/bin/grep 'error:' "$test_dir/isolation-negative.log" >&2 || true
  exit 1
fi
printf '%s\n' 'PASS: Production AppDelegate update entry points compile in Swift 5; the unisolated negative control is rejected.'
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -F "$sparkle_framework_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$sparkle_framework_dir" \
  -o "$app_dir/Contents/MacOS/AppUpdateTests" "${sources[@]}" "$project_root/Tools/AppUpdateTests/main.swift"
"$app_dir/Contents/MacOS/AppUpdateTests" "$snapshot_dir" -AppleLanguages "($test_language)" 2> >(tee "$test_dir/stderr.log" >&2)
if rg -q 'Unable to simultaneously satisfy constraints|Unsatisfiable constraints' "$test_dir/stderr.log"; then
  printf '%s\n' 'FAIL: Native update window emitted Auto Layout conflicts.' >&2
  exit 1
fi

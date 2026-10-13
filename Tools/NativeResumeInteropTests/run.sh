#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-resume-interop.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
native_test_deps="${NATIVE_PLAYBACK_DEPS:-$repo_root/deps}"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
sources=(Tools/NativeResumeInteropTests/Client.swift Tools/NativeResumeInteropTests/main.swift
  Tools/NativeResumeInteropTests/run.sh Tools/NativeResumeInteropTests/verify.py Tools/NativeResumeInteropTests/test_verify.py
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py other/playback_sources.sh
  "$native_test_deps/include/mpv/client.h" "$native_test_deps/lib/libmpv.2.dylib" "$ffmpeg_bin")
finish() {
  local status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  local source_status=$?
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
  local comparison_status=$?
  local dependency_status=0 generated_status=0
  if [[ -f "$test_dir/dependency-sha256.txt" ]]; then
    validate_native_test_dependencies
    dependency_status=$?
  fi
  if [[ -f "$test_dir/generated-before.sha256" ]]; then
    shasum -a 256 -c "$test_dir/generated-before.sha256" > "$test_dir/generated-validation.log" 2>&1
    generated_status=$?
  fi
  if [[ "$source_status" -ne 0 || "$comparison_status" -ne 0 || "$dependency_status" -ne 0 || "$generated_status" -ne 0 ]]; then status=1; fi
  printf '%s\n' "$status" > "$test_dir/runner-exit-status.txt"
  printf 'Artifacts: %s\n' "$test_dir"
  exit "$status"
}
trap finish EXIT
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
# shellcheck source=Tools/RenderTestSupport/native_dependencies.sh
source "$repo_root/Tools/RenderTestSupport/native_dependencies.sh"
prepare_native_test_dependencies
verify_native_test_runtime
python3 -B Tools/NativeResumeInteropTests/test_verify.py > "$test_dir/verifier-tests.log" 2>&1
for name in first second; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=20:d=8' \
    -c:v libx264 -pix_fmt yuv420p "$test_dir/$name.mp4"
done
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
printf 'sanitizer=%s\n' "${NATIVE_PLAYBACK_SANITIZER:-none}" > "$test_dir/mode.txt"
set +e
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
  -import-objc-header "$native_test_deps/include/mpv/client.h" \
  Tools/NativeResumeInteropTests/Client.swift Tools/NativeResumeInteropTests/main.swift \
  "$native_test_deps/lib/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
  -o "$test_dir/tests" > "$test_dir/compile.log" 2>&1
compile_status=$?
set -e
printf '%s\n' "$compile_status" > "$test_dir/compile-exit-status.txt"
test "$compile_status" -eq 0
shasum -a 256 "$test_dir/tests" "$test_dir/first.mp4" "$test_dir/second.mp4" > "$test_dir/generated-before.sha256"
for control in positive wrong-start disable-resume suppress-explicit-save suppress-quit-save; do
  work="$test_dir/$control"
  mkdir "$work"
  set +e
  /usr/bin/perl -e 'alarm 75; exec @ARGV' "$test_dir/tests" "$work" "$test_dir" "$control" > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  /usr/bin/grep -E '^FAIL:|^HARNESS_ERROR:|^Resume interop:|^EOF_POSITION:|^FILESYSTEM_CASE_SENSITIVE:' "$work/results.log" || true
  if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:' "$work/results.log"; then
    printf 'Unexpected sanitizer diagnostic\n'; exit 1
  fi
  python3 -B Tools/NativeResumeInteropTests/verify.py "$control" "$work/results.log" "$status" > "$work/verification.log"
done

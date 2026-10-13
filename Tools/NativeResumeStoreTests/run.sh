#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-resume-store.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
native_test_deps="${NATIVE_PLAYBACK_DEPS:-$repo_root/deps}"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
sources=(iina/NativePlayback/NativePlaybackResumeStore.swift
  Tools/NativeResumeStoreTests/main.swift Tools/NativeResumeStoreTests/prepare.py
  Tools/NativeResumeStoreTests/run.sh Tools/NativeResumeStoreTests/live_mpv.swift
  Tools/NativeResumeStoreTests/verify.py Tools/NativeResumeStoreTests/test_verify.py
  Tools/NativeResumeInteropTests/Client.swift Tools/RenderTestSupport/native_dependencies.sh
  Tools/RenderTestSupport/verify_native_dependencies.py other/verify_playback_distribution.py
  other/playback_sources.sh "$native_test_deps/include/mpv/client.h" "$native_test_deps/lib/libmpv.2.dylib" "$ffmpeg_bin")
finish() {
  local status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  local source_status=$?
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
  local comparison_status=$?
  local generated_status=0 dependency_status=0
  if [[ -f "$test_dir/generated.sha256" ]]; then
    shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log" 2>&1
    generated_status=$?
  fi
  if [[ -f "$test_dir/dependency-sha256.txt" ]]; then
    validate_native_test_dependencies
    dependency_status=$?
  fi
  if [[ "$source_status" -ne 0 || "$comparison_status" -ne 0 || "$generated_status" -ne 0 || "$dependency_status" -ne 0 ]]; then status=1; fi
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
python3 -B Tools/NativeResumeStoreTests/test_verify.py > "$test_dir/verifier-tests.log" 2>&1
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
printf 'sanitizer=%s\n' "${NATIVE_PLAYBACK_SANITIZER:-none}" > "$test_dir/mode.txt"
set +e
xcrun swiftc -swift-version 5 -warnings-as-errors -target x86_64-apple-macos10.15 -typecheck \
  iina/NativePlayback/NativePlaybackResumeStore.swift > "$test_dir/production-typecheck.log" 2>&1
typecheck_status=$?
set -e
printf '%s\n' "$typecheck_status" > "$test_dir/production-typecheck-exit-status.txt"
test "$typecheck_status" -eq 0
for control in positive bypass-final-gate private-fields overwrite-unknown; do
  work="$test_dir/$control"
  mkdir "$work" "$work/state"
  python3 -B Tools/NativeResumeStoreTests/prepare.py iina/NativePlayback/NativePlaybackResumeStore.swift "$work/Store.swift" "$control"
  set +e
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors -D NATIVE_RESUME_STORE_TESTING \
    "$work/Store.swift" Tools/NativeResumeStoreTests/main.swift -o "$work/tests" > "$work/compile.log" 2>&1
  compile_status=$?
  set -e
  printf '%s\n' "$compile_status" > "$work/compile-exit-status.txt"
  test "$compile_status" -eq 0
  shasum -a 256 "$work/Store.swift" "$work/tests" >> "$test_dir/generated.sha256"
  set +e
  /usr/bin/perl -e 'alarm 45; exec @ARGV' "$work/tests" "$work/state" > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  /usr/bin/grep -E '^FAIL:|^HARNESS_ERROR:|^Resume store:' "$work/results.log" || true
  if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:' "$work/results.log"; then
    printf 'Unexpected sanitizer diagnostic\n'; exit 1
  fi
  python3 -B Tools/NativeResumeStoreTests/verify.py "$control" "$work/results.log" "$status" > "$work/verification.log"
done
live="$test_dir/live"
mkdir "$live"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i 'testsrc2=s=160x96:r=20:d=8' \
  -c:v libx264 -pix_fmt yuv420p "$live/synthetic.mp4"
set +e
xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
  -import-objc-header "$native_test_deps/include/mpv/client.h" \
  iina/NativePlayback/NativePlaybackResumeStore.swift Tools/NativeResumeInteropTests/Client.swift \
  Tools/NativeResumeStoreTests/live_mpv.swift \
  "$native_test_deps/lib/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
  -o "$live/tests" > "$live/compile.log" 2>&1
compile_status=$?
set -e
printf '%s\n' "$compile_status" > "$live/compile-exit-status.txt"
test "$compile_status" -eq 0
shasum -a 256 "$live/tests" "$live/synthetic.mp4" >> "$test_dir/generated.sha256"
set +e
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$live/tests" "$live" > "$live/results.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$live/exit-status.txt"
/usr/bin/grep -E '^FAIL:|^HARNESS_ERROR:|^Resume store live:' "$live/results.log" || true
if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:' "$live/results.log"; then
  printf 'Unexpected sanitizer diagnostic\n'; exit 1
fi
python3 -B Tools/NativeResumeStoreTests/verify.py live "$live/results.log" "$status" > "$live/verification.log"

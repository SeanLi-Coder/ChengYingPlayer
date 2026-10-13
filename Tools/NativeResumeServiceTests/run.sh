#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-resume-service.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
sources=(iina/NativePlayback/NativePlaybackResumeStore.swift iina/NativePlayback/NativePlaybackResumeService.swift
  Tools/NativeResumeServiceTests/Boundary.swift Tools/NativeResumeServiceTests/main.swift
  Tools/NativeResumeServiceTests/prepare.py Tools/NativeResumeServiceTests/run.sh
  Tools/NativeResumeServiceTests/Cleanup.swift Tools/NativeResumeServiceTests/verify.py
  Tools/NativeResumeServiceTests/test_verify.py)
controls=(positive premature-finish overwrite-baseline ignore-authoritative save-compatibility ignore-kvo ignore-epochs duplicate-delivery)
finish() {
  local status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  local source_status=$?
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
  local comparison_status=$?
  local generated_status=0 cleanup_status=0
  if [[ -f "$test_dir/generated.sha256" ]]; then
    shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log" 2>&1
    generated_status=$?
  fi
  if [[ -x "$test_dir/cleanup" ]]; then
    for control in "${controls[@]}"; do
      if [[ -d "$test_dir/$control" ]]; then
        /usr/bin/perl -e 'alarm 15; exec @ARGV' "$test_dir/cleanup" "$test_dir/$control/state/owned-domains.txt" \
          > "$test_dir/$control/cleanup.log" 2>&1
        local current_cleanup=$?
        printf '%s\n' "$current_cleanup" > "$test_dir/$control/cleanup-exit-status.txt"
        if [[ "$current_cleanup" -ne 0 ]]; then cleanup_status=1; fi
      fi
    done
  fi
  if [[ "$source_status" -ne 0 || "$comparison_status" -ne 0 || "$generated_status" -ne 0 || "$cleanup_status" -ne 0 ]]; then status=1; fi
  printf '%s\n' "$status" > "$test_dir/runner-exit-status.txt"
  printf 'Artifacts: %s\n' "$test_dir"
  exit "$status"
}
trap finish EXIT
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
printf 'sanitizer=%s\n' "${NATIVE_PLAYBACK_SANITIZER:-none}" > "$test_dir/mode.txt"
set +e
xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors Tools/NativeResumeServiceTests/Cleanup.swift -o "$test_dir/cleanup" > "$test_dir/cleanup-compile.log" 2>&1
cleanup_compile_status=$?
set -e
printf '%s\n' "$cleanup_compile_status" > "$test_dir/cleanup-compile-exit-status.txt"
test "$cleanup_compile_status" -eq 0
shasum -a 256 "$test_dir/cleanup" > "$test_dir/generated.sha256"
python3 -B Tools/NativeResumeServiceTests/test_verify.py > "$test_dir/verifier-selftests.log" 2>&1
for control in "${controls[@]}"; do
  work="$test_dir/$control"
  mkdir "$work" "$work/state"
  python3 -B Tools/NativeResumeServiceTests/prepare.py iina/NativePlayback/NativePlaybackResumeService.swift "$work/Service.swift" "$control"
  if [[ "$control" = positive ]]; then
    set +e
    xcrun swiftc -swift-version 5 -warnings-as-errors -target x86_64-apple-macos10.15 -typecheck \
      iina/NativePlayback/NativePlaybackResumeStore.swift Tools/NativeResumeServiceTests/Boundary.swift "$work/Service.swift" \
      > "$test_dir/production-typecheck.log" 2>&1
    typecheck_status=$?
    set -e
    printf '%s\n' "$typecheck_status" > "$test_dir/production-typecheck-exit-status.txt"
    test "$typecheck_status" -eq 0
  fi
  set +e
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors -D NATIVE_RESUME_STORE_TESTING \
    iina/NativePlayback/NativePlaybackResumeStore.swift "$work/Service.swift" \
    Tools/NativeResumeServiceTests/Boundary.swift Tools/NativeResumeServiceTests/main.swift -o "$work/tests" > "$work/compile.log" 2>&1
  compile_status=$?
  set -e
  printf '%s\n' "$compile_status" > "$work/compile-exit-status.txt"
  test "$compile_status" -eq 0
  shasum -a 256 "$work/Service.swift" "$work/tests" >> "$test_dir/generated.sha256"
  set +e
  /usr/bin/perl -e 'alarm 45; exec @ARGV' "$work/tests" "$work/state" > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  /usr/bin/grep -E '^FAIL:|^HARNESS_ERROR:|^Resume service:' "$work/results.log" || true
  python3 -B Tools/NativeResumeServiceTests/verify.py "$control" "$work/results.log" "$status" | tee "$work/verification.log"
done

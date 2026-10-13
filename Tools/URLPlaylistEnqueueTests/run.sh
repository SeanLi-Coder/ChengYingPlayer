#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/url-enqueue-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
sources=(iina/Atomic.swift iina/Lock.swift iina/PlayerState.swift iina/MPVCommand.swift iina/MPVOption.swift
  iina/Updates/UpdateWorkAdmission.swift iina/VideoTools/VideoToolsModels.swift
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsRotationIntent.swift
  iina/VideoTools/VideoToolsRotationCoordinator.swift iina/VideoTools/VideoToolsShortcuts.swift)
shasum -a 256 "${sources[@]}" iina/PlayerCore.swift iina/AppDelegate.swift iina/VideoTools/VideoToolsPlayerBridge.swift \
  Tools/NativeRotationHandoffTests/Boundary.swift Tools/URLPlaylistEnqueueTests/*.swift \
  Tools/URLPlaylistEnqueueTests/run.sh > "$test_dir/inputs.sha256"
finish_evidence() {
  status=$?
  trap - EXIT
  set +e
  shasum -a 256 -c "$test_dir/inputs.sha256" > "$test_dir/source-check.log" 2>&1
  source_status=$?
  if [[ "$status" -eq 0 && "$source_status" -ne 0 ]]; then status=1; fi
  printf 'Runner exit: %s; source check: %s\n' "$status" "$source_status"
  exit "$status"
}
trap finish_evidence EXIT
compiler=(xcrun swiftc -swift-version 5)
case "${URL_ENQUEUE_SANITIZER:-}" in
  "") ;;
  address|thread) compiler+=("-sanitize=$URL_ENQUEUE_SANITIZER") ;;
  *) exit 2 ;;
esac
for mutation in positive early-append drop-owner drop-pause-restore ignore-result empty-playlist unguarded-osd stale-tail-receipt stale-file-start; do
  mode="$mutation"
  if [[ "$mutation" == positive ]]; then mode=""; fi
  URL_ENQUEUE_NEGATIVE="$mode" xcrun swift Tools/URLPlaylistEnqueueTests/extract.swift "$repo_root" "$test_dir/$mutation.swift"
  "${compiler[@]}" "${sources[@]}" Tools/NativeRotationHandoffTests/Boundary.swift \
    Tools/URLPlaylistEnqueueTests/EnqueueServices.swift Tools/URLPlaylistEnqueueTests/URLDispatchServices.swift \
    "$test_dir/$mutation.swift" Tools/URLPlaylistEnqueueTests/main.swift \
    -o "$test_dir/$mutation"
  set +e
  /usr/bin/perl -e 'alarm 20; exec @ARGV' "$test_dir/$mutation" 2>&1 | tee "$test_dir/$mutation.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "$mutation" == positive ]]; then expected_status=0; else expected_status=1; fi
  [[ "${statuses[0]}" -eq "$expected_status" && "${statuses[1]}" -eq 0 ]]
  if /usr/bin/grep -Eq 'ERROR: AddressSanitizer|WARNING: ThreadSanitizer|SUMMARY: (AddressSanitizer|ThreadSanitizer)|Sanitizer:DEADLYSIGNAL|runtime error:' "$test_dir/$mutation.log"; then
    printf 'Unexpected sanitizer diagnostic in %s\n' "$mutation" >&2
    exit 1
  fi
  case "$mutation" in
    early-append) expected='FAIL: No append reaches the idle MPV during native capture' ;;
    drop-owner) expected='FAIL: Same-URL user reopen cancels the old enqueue exactly once' ;;
    drop-pause-restore) expected='FAIL: Latest pause intent remains owned during retirement' ;;
    ignore-result) expected='FAIL: Failed MPV commands never count as success' ;;
    empty-playlist) expected='FAIL: The actual URL branch queues during an empty compatibility playlist' ;;
    unguarded-osd) expected='FAIL: Final asynchronous OSD checks the receipt after notification reentry' ;;
    stale-tail-receipt) expected='FAIL: A callback opening media suppresses later stale success receipts' ;;
    stale-file-start) expected='FAIL: A non-owned MPV file-start invalidates queued success OSD' ;;
    *) expected='' ;;
  esac
  if [[ -n "$expected" ]]; then /usr/bin/grep -Fq "$expected" "$test_dir/$mutation.log"; fi
done

#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/rotation-handoff-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
git rev-parse HEAD > "$test_dir/base-commit.txt"
printf '%s\n' "${ROTATION_HANDOFF_SANITIZER:-normal}" > "$test_dir/mode.txt"
sources=(iina/Atomic.swift iina/Lock.swift iina/PlayerState.swift iina/MPVCommand.swift iina/MPVOption.swift
  iina/Updates/UpdateWorkAdmission.swift iina/VideoTools/VideoToolsModels.swift
  iina/VideoTools/VideoToolsLoopPolicy.swift iina/VideoTools/VideoToolsRotationIntent.swift
  iina/VideoTools/VideoToolsRotationCoordinator.swift iina/VideoTools/VideoToolsShortcuts.swift)
shasum -a 256 "${sources[@]}" iina/PlayerCore.swift iina/PlayerWindowController.swift \
  iina/QuickSettingViewController.swift iina/VideoTools/VideoToolsViewController.swift \
  iina/VideoTools/VideoToolsPlayerBridge.swift Tools/NativeRotationHandoffTests/*.swift \
  Tools/URLPlaylistEnqueueTests/EnqueueServices.swift \
  Tools/NativeRotationHandoffTests/run.sh > "$test_dir/inputs.sha256"
finish_evidence() {
  original_status=$?
  trap - EXIT
  set +e
  if compgen -G "$test_dir/*.swift" > /dev/null; then
    shasum -a 256 "$test_dir/"*.swift > "$test_dir/generated.sha256"
    generated_status=$?
  else
    generated_status=0
  fi
  shasum -a 256 -c "$test_dir/inputs.sha256" > "$test_dir/source-check.log" 2>&1
  source_status=$?
  if [[ "$original_status" -eq 0 && ( "$source_status" -ne 0 || "$generated_status" -ne 0 ) ]]; then original_status=1; fi
  printf 'Runner exit: %s; source check: %s; generated manifest: %s\n' "$original_status" "$source_status" "$generated_status"
  exit "$original_status"
}
trap finish_evidence EXIT
compiler=(xcrun swiftc -swift-version 5)
case "${ROTATION_HANDOFF_SANITIZER:-}" in
  "") ;;
  address|thread) compiler+=("-sanitize=$ROTATION_HANDOFF_SANITIZER") ;;
  *) printf 'Unsupported sanitizer\n' >&2; exit 2 ;;
esac
for mutation in positive loaded-only resurrect-restore unowned-restore drop-playback-state; do
  mode="$mutation"
  if [[ "$mutation" == positive ]]; then mode=""; fi
  ROTATION_HANDOFF_NEGATIVE="$mode" xcrun swift Tools/NativeRotationHandoffTests/extract.swift \
    "$repo_root" "$test_dir/$mutation.swift"
  "${compiler[@]}" "${sources[@]}" Tools/NativeRotationHandoffTests/Boundary.swift \
    Tools/URLPlaylistEnqueueTests/EnqueueServices.swift \
    "$test_dir/$mutation.swift" Tools/NativeRotationHandoffTests/main.swift -o "$test_dir/$mutation"
  set +e
  /usr/bin/perl -e 'alarm 25; exec @ARGV' "$test_dir/$mutation" 2>&1 | tee "$test_dir/$mutation.log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  if [[ "$mutation" == positive ]]; then expected_exit=0; else expected_exit=1; fi
  [[ "${statuses[0]}" -eq "$expected_exit" && "${statuses[1]}" -eq 0 ]]
  case "$mutation" in
    loaded-only) expected='FAIL: Rotation during stopping is accumulated' ;;
    resurrect-restore) expected='FAIL: Cancelled action is not resurrected by retirement completion' ;;
    unowned-restore) expected='FAIL: An unrelated restore ID cannot exempt a seek from cancellation' ;;
    drop-playback-state) expected='FAIL: Cancelling export retains same-media volume speed viewport and A/B' ;;
    *) expected='' ;;
  esac
  if [[ -n "$expected" ]]; then rg -Fq "$expected" "$test_dir/$mutation.log"; fi
done

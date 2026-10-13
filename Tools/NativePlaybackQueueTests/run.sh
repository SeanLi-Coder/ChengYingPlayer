#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-queue-model-tests.XXXXXX")"
sources=(iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaylistPlaybackPolicy.swift
  Tools/NativePlaybackQueueTests/main.swift Tools/NativePlaybackQueueTests/prepare.swift
  Tools/NativePlaybackQueueTests/run.sh Tools/NativePlaybackQueueTests/verify_negative.swift)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
for control in positive stale-checkpoint same-generation stale-eof; do
  work="$test_dir/$control"
  mkdir "$work"
  xcrun swift Tools/NativePlaybackQueueTests/prepare.swift iina/PlaybackBackend/NativePlaybackQueue.swift \
    "$work/Queue.swift" "$control"
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
    iina/PlaylistPlaybackPolicy.swift "$work/Queue.swift" Tools/NativePlaybackQueueTests/main.swift -o "$work/tests"
  set +e
  /usr/bin/perl -e 'alarm 15; exec @ARGV' "$work/tests" > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  tail -n 1 "$work/results.log"
  if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)' "$work/results.log"; then
    printf 'Unexpected sanitizer diagnostic\n'; exit 1
  fi
  if [ "$control" = positive ]; then
    test "$status" -eq 0
  else
    test "$status" -eq 1
    /usr/bin/grep -E '^FAIL:' "$work/results.log" > "$work/failures.log"
    xcrun swift Tools/NativePlaybackQueueTests/verify_negative.swift "$control" "$work/failures.log"
  fi
done
shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
printf 'Artifacts: %s\n' "$test_dir"

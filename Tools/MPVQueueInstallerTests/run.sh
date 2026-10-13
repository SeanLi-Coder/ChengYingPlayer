#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/mpv-queue-installer-tests.XXXXXX")"
sources=(iina/PlaybackBackend/MPVQueueInstaller.swift iina/PlaybackBackend/NativePlaybackQueue.swift
  iina/PlaylistPlaybackPolicy.swift iina/MPVNode.swift Tools/MPVQueueInstallerTests/LiveClient.swift
  Tools/MPVQueueInstallerTests/main.swift Tools/MPVQueueInstallerTests/run.sh
  Tools/MPVQueueInstallerTests/prepare.swift Tools/MPVQueueInstallerTests/verify_negative.swift deps/lib/libmpv.2.dylib)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
finish() {
  local status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  local hash_status=$?
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
  local comparison_status=$?
  local generated=()
  local candidate
  for candidate in "$test_dir/red.mp4" "$test_dir/blue.mp4" "$test_dir"/*/Installer.swift; do
    if [ -f "$candidate" ]; then generated+=("$candidate"); fi
  done
  if [ "${#generated[@]}" -gt 0 ]; then
    shasum -a 256 "${generated[@]}" > "$test_dir/generated.sha256"
    if [ "$?" -ne 0 ] && [ "$status" -eq 0 ]; then status=1; fi
  fi
  if [ "$status" -eq 0 ] && { [ "$hash_status" -ne 0 ] || [ "$comparison_status" -ne 0 ]; }; then status=1; fi
  printf '%s\n' "$status" > "$test_dir/runner-exit-status.txt"
  printf 'Artifacts: %s\n' "$test_dir"
  exit "$status"
}
trap finish EXIT
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
for color in red blue; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=3" \
    -c:v libx264 -pix_fmt yuv420p "$test_dir/$color.mp4"
done
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
for control in positive deadline activation-status readback-cancel owner old-end-event prefix; do
  work="$test_dir/$control"
  mkdir "$work"
  xcrun swift Tools/MPVQueueInstallerTests/prepare.swift iina/PlaybackBackend/MPVQueueInstaller.swift "$work/Installer.swift" "$control"
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
    -import-objc-header deps/include/mpv/client.h "$work/Installer.swift" \
    iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaylistPlaybackPolicy.swift iina/MPVNode.swift \
    Tools/MPVQueueInstallerTests/LiveClient.swift Tools/MPVQueueInstallerTests/main.swift \
    deps/lib/libmpv.2.dylib -Xlinker -rpath -Xlinker "$repo_root/deps/lib" -o "$work/tests"
  set +e
  /usr/bin/perl -e 'alarm 75; exec @ARGV' "$work/tests" "$test_dir" > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  /usr/bin/grep -E '^FAIL:|^Queue installer:' "$work/results.log" || true
  if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)' "$work/results.log"; then
    printf 'Unexpected sanitizer diagnostic\n'; exit 1
  fi
  if [ "$control" = positive ]; then
    test "$status" -eq 0
  else
    test "$status" -eq 1
    /usr/bin/grep -E '^FAIL:' "$work/results.log" > "$work/failures.log"
    xcrun swift Tools/MPVQueueInstallerTests/verify_negative.swift "$control" "$work/failures.log"
  fi
done

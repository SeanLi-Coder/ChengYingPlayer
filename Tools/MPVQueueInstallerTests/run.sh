#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/mpv-queue-installer-tests.XXXXXX")"
printf 'Artifacts: %s\n' "$test_dir"
native_test_deps="${NATIVE_PLAYBACK_DEPS:-$repo_root/deps}"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
sources=(iina/PlaybackBackend/MPVQueueInstaller.swift iina/PlaybackBackend/NativePlaybackQueue.swift
  iina/PlaylistPlaybackPolicy.swift iina/MPVNode.swift Tools/MPVQueueInstallerTests/LiveClient.swift
  Tools/MPVQueueInstallerTests/main.swift Tools/MPVQueueInstallerTests/run.sh
  Tools/MPVQueueInstallerTests/prepare.swift Tools/MPVQueueInstallerTests/verify_negative.swift
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py "$native_test_deps/include/mpv/client.h" "$native_test_deps/lib/libmpv.2.dylib"
  "$ffmpeg_bin")
finish() {
  local status=$?
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  local hash_status=$?
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
  local comparison_status=$?
  local dependency_status=0 generated_status=0
  if [[ -f "$test_dir/dependency-sha256.txt" ]]; then
    validate_native_test_dependencies
    dependency_status=$?
  fi
  local manifest
  for manifest in "$test_dir/fixture-before.sha256" "$test_dir"/*/generated-before.sha256; do
    if [[ -f "$manifest" ]]; then
      shasum -a 256 -c "$manifest" > "${manifest%.sha256}-validation.log" 2>&1
      if [[ "$?" -ne 0 ]]; then generated_status=1; fi
    fi
  done
  local generated=()
  local candidate
  for candidate in "$test_dir/red.mp4" "$test_dir/blue.mp4" "$test_dir"/*/Installer.swift; do
    if [ -f "$candidate" ]; then generated+=("$candidate"); fi
  done
  if [ "${#generated[@]}" -gt 0 ]; then
    shasum -a 256 "${generated[@]}" > "$test_dir/generated.sha256"
    if [ "$?" -ne 0 ] && [ "$status" -eq 0 ]; then status=1; fi
  fi
  if [ "$status" -eq 0 ] && { [ "$hash_status" -ne 0 ] || [ "$comparison_status" -ne 0 ] || [ "$dependency_status" -ne 0 ] || [ "$generated_status" -ne 0 ]; }; then status=1; fi
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
for color in red blue; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=3" \
    -c:v libx264 -pix_fmt yuv420p "$test_dir/$color.mp4"
done
shasum -a 256 "$test_dir/red.mp4" "$test_dir/blue.mp4" > "$test_dir/fixture-before.sha256"
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
controls=(positive deadline activation-status readback-cancel owner old-end-event prefix cleanup-unload)
runtime_arguments=()
if [[ -n "${MPV_QUEUE_PARTIAL_CANCELLATIONS:-}" ]]; then
  case "$MPV_QUEUE_PARTIAL_CANCELLATIONS" in ''|*[!0-9]*) exit 2 ;; esac
  if (( MPV_QUEUE_PARTIAL_CANCELLATIONS < 1 || MPV_QUEUE_PARTIAL_CANCELLATIONS > 500 )); then exit 2; fi
  controls=(positive)
  runtime_arguments+=("$MPV_QUEUE_PARTIAL_CANCELLATIONS")
fi
printf 'sanitizer=%s\npartial_cancellations=%s\n' "${NATIVE_PLAYBACK_SANITIZER:-none}" \
  "${MPV_QUEUE_PARTIAL_CANCELLATIONS:-0}" > "$test_dir/mode.txt"
for control in "${controls[@]}"; do
  work="$test_dir/$control"
  mkdir "$work"
  xcrun swift Tools/MPVQueueInstallerTests/prepare.swift iina/PlaybackBackend/MPVQueueInstaller.swift "$work/Installer.swift" "$control"
  shasum -a 256 "$work/Installer.swift" > "$work/generated-before.sha256"
  set +e
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
    -import-objc-header "$native_test_deps/include/mpv/client.h" "$work/Installer.swift" \
    iina/PlaybackBackend/NativePlaybackQueue.swift iina/PlaylistPlaybackPolicy.swift iina/MPVNode.swift \
    Tools/MPVQueueInstallerTests/LiveClient.swift Tools/MPVQueueInstallerTests/main.swift \
    "$native_test_deps/lib/libmpv.2.dylib" -Xlinker -rpath -Xlinker "$native_test_deps/lib" -o "$work/tests" \
    > "$work/compile.log" 2>&1
  compile_status=$?
  set -e
  printf '%s\n' "$compile_status" > "$work/compile-exit-status.txt"
  test "$compile_status" -eq 0
  shasum -a 256 "$work/tests" >> "$work/generated-before.sha256"
  control_arguments=()
  if [ "${#runtime_arguments[@]}" -gt 0 ]; then control_arguments=("${runtime_arguments[@]}"); fi
  if [ "$control" = cleanup-unload ]; then control_arguments=(cleanup-hooks); fi
  set +e
  /usr/bin/perl -e 'alarm 75; exec @ARGV' "$work/tests" "$test_dir" ${control_arguments[@]+"${control_arguments[@]}"} > "$work/results.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$work/exit-status.txt"
  /usr/bin/grep -E '^FAIL:|^Queue installer( stress)?:' "$work/results.log" || true
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

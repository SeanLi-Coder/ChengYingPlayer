#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-queue-mpv-probe.XXXXXX")"
sources=(iina/PlayerCore.swift iina/MPVCommand.swift iina/MPVOption.swift iina/MPVHook.swift
  Tools/PlaybackModeLiveTests/main.swift Tools/NativePlaybackQueueTests/prepare_live.swift
  Tools/NativePlaybackQueueTests/MPVNavigationProbe.swift Tools/NativePlaybackQueueTests/run_mpv_probe.sh
  deps/lib/libmpv.2.dylib)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
for color in red blue; do
  "$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "color=c=$color:s=160x96:r=20:d=8" \
    -c:v libx264 -pix_fmt yuv420p "$test_dir/$color.mp4"
done
xcrun swift Tools/NativePlaybackQueueTests/prepare_live.swift "$repo_root" "$test_dir/main.swift"
xcrun swiftc -swift-version 5 -warnings-as-errors -import-objc-header deps/include/mpv/client.h \
  iina/MPVCommand.swift iina/MPVOption.swift iina/MPVHook.swift "$test_dir/main.swift" \
  deps/lib/libmpv.2.dylib -Xlinker -rpath -Xlinker "$repo_root/deps/lib" -o "$test_dir/probe"
set +e
/usr/bin/perl -e 'alarm 30; exec @ARGV' "$test_dir/probe" "$test_dir" > "$test_dir/results.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$test_dir/exit-status.txt"
/usr/bin/grep -E 'MPV_NAVIGATION|Live navigation|FAIL:' "$test_dir/results.log" || true
shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
printf 'Artifacts: %s\n' "$test_dir"
exit "$status"

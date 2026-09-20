#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
library_dir="${PLAYBACK_ROTATION_LIBRARY_DIR:-$project_root/deps/lib}"
include_dir="${PLAYBACK_ROTATION_INCLUDE_DIR:-$project_root/deps/include}"
ffmpeg="${PLAYBACK_ROTATION_FFMPEG:-$project_root/deps/executable/ffmpeg}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-rotation.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
ulimit -c 0

xcrun clang -Wall -Wextra -Werror -O2 -I "$include_dir" \
  "$project_root/Tools/PlaybackRotationTests/main.c" "$library_dir/libmpv.2.dylib" \
  -Wl,-rpath,"$library_dir" -o "$test_dir/PlaybackRotationTests"
"$ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'testsrc2=size=96x64:rate=30:duration=0.6' -an -c:v libx264 \
  -preset ultrafast -pix_fmt yuv420p "$test_dir/generated.mp4"

# This process deadline preserves SIGABRT as a failure and bounds core hangs.
if [[ $# -gt 0 ]]; then
  /usr/bin/perl -e 'alarm 30; exec @ARGV or die "Unable to run rotation test: $!";' \
    "$test_dir/PlaybackRotationTests" "$library_dir/libmpv.2.dylib" \
    "$test_dir/generated.mp4" "$@"
else
  for phase in unload after-end; do
    for transition in eof stop replace resume playlist; do
      /usr/bin/perl -e 'alarm 30; exec @ARGV or die "Unable to run rotation test: $!";' \
        "$test_dir/PlaybackRotationTests" "$library_dir/libmpv.2.dylib" \
        "$test_dir/generated.mp4" "$phase" "$transition"
    done
  done
fi

#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-rate-eof.XXXXXX")"
source "$repo_root/Tools/RenderTestSupport/native_dependencies.sh"
prepare_native_test_dependencies
verify_native_test_runtime
sources=(iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift Tools/NativeRateEOFTests/main.swift
  Tools/NativeRateEOFTests/run.sh Tools/NativeRateEOFTests/prepare.py Tools/NativeRateEOFTests/verify_negative.py
  Tools/RenderTestSupport/native_dependencies.sh
  Tools/RenderTestSupport/verify_native_dependencies.py other/verify_playback_distribution.py)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
finish() {
  local status=$?
  trap - EXIT
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  if ! diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-diff.txt"; then status=1; fi
  if [[ -f "$test_dir/fixture-sha256.txt" ]]; then
    if ! shasum -a 256 -c "$test_dir/fixture-sha256.txt" > "$test_dir/fixture-validation.log"; then status=1; fi
  fi
  if [[ -f "$test_dir/generated-sha256.txt" ]]; then
    if ! shasum -a 256 -c "$test_dir/generated-sha256.txt" > "$test_dir/generated-validation.log"; then status=1; fi
  fi
  if ! validate_native_test_dependencies; then status=1; fi
  printf '%s\n' "$status" > "$test_dir/exit-status.txt"
  printf 'Artifacts: %s\n' "$test_dir"
  exit "$status"
}
trap finish EXIT
printf 'Artifacts: %s\n' "$test_dir"
sanitizer_mode="${NATIVE_PLAYBACK_SANITIZER:-}"
clang_sanitizer=""
swift_sanitizer=""
case "$sanitizer_mode" in
  "") ;;
  address|thread) clang_sanitizer="-fsanitize=$sanitizer_mode"; swift_sanitizer="-sanitize=$sanitizer_mode" ;;
  *) printf 'Unsupported sanitizer.\n' >&2; exit 2 ;;
esac
negative="${NATIVE_RATE_EOF_NEGATIVE:-0}"
session_source="iina/NativePlayback/NativePlaybackSession.swift"
case "$negative" in
  0) ;;
  1) session_source="$test_dir/NativePlaybackSession.swift"
     python3 Tools/NativeRateEOFTests/prepare.py iina/NativePlayback/NativePlaybackSession.swift "$session_source" ;;
  *) printf 'Unsupported negative control.\n' >&2; exit 2 ;;
esac
printf 'sanitizer=%s\nnegative_control=%s\n' "$sanitizer_mode" "$negative" > "$test_dir/mode.txt"
compile() {
xcrun clang ${clang_sanitizer:+"$clang_sanitizer"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 \
  -I "$native_test_deps/include" -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc ${swift_sanitizer:+"$swift_sanitizer"} -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
  "$session_source" Tools/NativeRateEOFTests/main.swift "$test_dir/decoder.o" \
  "${native_test_libraries[@]}" -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
  -o "$test_dir/rate-eof-tests"
}
set +e
( set -e; compile ) 2>&1 | tee "$test_dir/compile.log"
compile_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${compile_status[0]}" > "$test_dir/compile-status.txt"
if [[ "${compile_status[0]}" != 0 ]]; then exit "${compile_status[0]}"; fi
if [[ "${compile_status[1]}" != 0 ]]; then exit "${compile_status[1]}"; fi
shasum -a 256 "$test_dir/decoder.o" "$test_dir/rate-eof-tests" "$session_source" > "$test_dir/generated-sha256.txt"
if [[ "${BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=160x96:r=25:d=1.2 -f lavfi -i anullsrc=r=48000:cl=stereo -t 1.2 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/pcm.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=160x96:r=25:d=1.2 -f lavfi -i anullsrc=r=48000:cl=stereo -t 1.2 \
  -c:v libx264 -preset fast -bf 3 -g 25 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac "$test_dir/aac.mp4"
shasum -a 256 "$test_dir/pcm.mkv" "$test_dir/aac.mp4" > "$test_dir/fixture-sha256.txt"
set +e
/usr/bin/perl -e 'alarm 60; exec @ARGV' "$test_dir/rate-eof-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
run_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${run_status[0]}" > "$test_dir/execution-status.txt"
if [[ "${run_status[0]}" != 0 ]]; then exit "${run_status[0]}"; fi
exit "${run_status[1]}"

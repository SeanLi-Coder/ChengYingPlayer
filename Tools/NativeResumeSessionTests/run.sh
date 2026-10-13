#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-resume-session.XXXXXX")"
source "$repo_root/Tools/RenderTestSupport/native_dependencies.sh"
prepare_native_test_dependencies
verify_native_test_runtime
sources=(iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift
  iina/NativePlayback/NativePlaybackSession.swift Tools/NativeResumeSessionTests/main.swift
  Tools/NativeResumeSessionTests/run.sh Tools/NativeResumeSessionTests/prepare.py
  Tools/NativeResumeSessionTests/verify.py Tools/RenderTestSupport/native_dependencies.sh
  Tools/RenderTestSupport/verify_native_dependencies.py other/verify_playback_distribution.py)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
finish() {
  local status=$?
  trap - EXIT
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
  if ! diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-diff.txt"; then status=1; fi
  for manifest in generated fixture; do
    if [[ -f "$test_dir/$manifest-sha256.txt" ]]; then
      if ! shasum -a 256 -c "$test_dir/$manifest-sha256.txt" > "$test_dir/$manifest-validation.log"; then status=1; fi
    fi
  done
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
negative="${NATIVE_RESUME_SESSION_NEGATIVE:-none}"
session_source="iina/NativePlayback/NativePlaybackSession.swift"
if [[ "$negative" != none ]]; then
  session_source="$test_dir/NativePlaybackSession.swift"
  python3 -B Tools/NativeResumeSessionTests/prepare.py iina/NativePlayback/NativePlaybackSession.swift "$session_source" "$negative"
fi
printf 'sanitizer=%s\nnegative_control=%s\n' "$sanitizer_mode" "$negative" > "$test_dir/mode.txt"
compile() {
  xcrun clang ${clang_sanitizer:+"$clang_sanitizer"} -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 \
    -I "$native_test_deps/include" -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
  xcrun swiftc ${swift_sanitizer:+"$swift_sanitizer"} -swift-version 5 -target arm64-apple-macos12 \
    -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
    iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
    "$session_source" Tools/NativeResumeSessionTests/main.swift "$test_dir/decoder.o" \
    "${native_test_libraries[@]}" -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
    -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
    -o "$test_dir/resume-session-tests"
}
set +e
( set -e; compile ) 2>&1 | tee "$test_dir/compile.log"
compile_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${compile_status[0]}" > "$test_dir/compile-status.txt"
if [[ "${compile_status[0]}" != 0 ]]; then exit "${compile_status[0]}"; fi
if [[ "${compile_status[1]}" != 0 ]]; then exit "${compile_status[1]}"; fi
shasum -a 256 "$test_dir/decoder.o" "$test_dir/resume-session-tests" "$session_source" > "$test_dir/generated-sha256.txt"
if [[ "${BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=160x96:r=25:d=6 -f lavfi -i anullsrc=r=48000:cl=stereo -t 6 \
  -c:v ffv1 -pix_fmt yuv420p -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a pcm_f32le "$test_dir/long.mkv"
"$ffmpeg_bin" -hide_banner -loglevel error \
  -f lavfi -i testsrc2=s=160x96:r=25:d=1.2 -f lavfi -i anullsrc=r=48000:cl=stereo -t 1.2 \
  -c:v libx264 -preset fast -bf 3 -g 25 -pix_fmt yuv420p -color_range tv \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac "$test_dir/short.mp4"
shasum -a 256 "$test_dir/long.mkv" "$test_dir/short.mp4" > "$test_dir/fixture-sha256.txt"
set +e
/usr/bin/perl -e 'alarm 90; exec @ARGV' "$test_dir/resume-session-tests" "$test_dir" 2>&1 | tee "$test_dir/results.log"
run_status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${run_status[0]}" > "$test_dir/execution-status.txt"
if [[ "${run_status[1]}" != 0 ]]; then exit "${run_status[1]}"; fi
python3 -B Tools/NativeResumeSessionTests/verify.py "$test_dir" "$negative"

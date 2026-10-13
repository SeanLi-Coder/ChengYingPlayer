#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-seek-latency.XXXXXX")"
source "$repo_root/Tools/RenderTestSupport/native_dependencies.sh"
prepare_native_test_dependencies
verify_native_test_runtime
session_source="${NATIVE_PLAYBACK_SESSION_SOURCE:-iina/NativePlayback/NativePlaybackSession.swift}"
sources=(iina/NativePlayback/CYNMediaDecoder.h iina/NativePlayback/CYNMediaDecoder.m
  iina/NativePlayback/NativePlaybackSampleGate.swift iina/NativePlayback/NativePlaybackSession.swift
  Tools/NativeSeekLatencyTests/main.swift Tools/NativeSeekLatencyTests/prepare.py Tools/NativeSeekLatencyTests/run.sh
  Tools/NativeSeekLatencyTests/verify.py Tools/NativeSeekLatencyTests/test_gate.py
  Tools/NativeSeekLatencyTests/evidence.py Tools/NativeSeekLatencyTests/test_evidence.py
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py "$session_source")
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
child_status=-1
tee_status=-1
finish() {
  local result=$?
  local source_status=0 generated_status=1 dependency_status=1 results_status=1
  trap - EXIT
  set +e
  shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256" || source_status=1
  diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-diff.txt" || source_status=1
  if [[ -f "$test_dir/generated.sha256" ]]; then
    shasum -a 256 -c "$test_dir/generated.sha256" > "$test_dir/generated-validation.log"
    generated_status=$?
  fi
  validate_native_test_dependencies
  dependency_status=$?
  if [[ -f "$test_dir/report.json" && -f "$test_dir/results.log" ]]; then
    shasum -a 256 "$test_dir/report.json" "$test_dir/results.log" > "$test_dir/results.sha256"
    results_status=$?
  fi
  if [[ "$source_status" != 0 || "$generated_status" != 0 || "$dependency_status" != 0 || "$results_status" != 0 ]]; then result=1; fi
  python3 -B - "$test_dir/evidence-status.json" "$child_status" "$tee_status" \
    "$source_status" "$generated_status" "$dependency_status" "$results_status" "$result" <<'PY'
import json
from pathlib import Path
import sys
keys = ("child", "tee", "source", "generated", "dependencies", "results", "runner")
Path(sys.argv[1]).write_text(json.dumps(dict(version=2, **dict(zip(keys, map(int, sys.argv[2:])))), sort_keys=True) + "\n")
PY
  if [[ "$?" != 0 ]]; then result=1; fi
  printf '%s\n' "$result" > "$test_dir/exit-status.txt"
  printf 'Artifacts: %s\n' "$test_dir"
  exit "$result"
}
trap finish EXIT
mode="${NATIVE_SEEK_MODE:-candidate}"
case "$mode" in baseline|candidate) ;; *) exit 2 ;; esac
case "${NATIVE_SEEK_INSTRUMENT:-1}" in 0|1) ;; *) exit 2 ;; esac
prepare_args=()
if [[ -n "${NATIVE_SEEK_REVISION:-}" ]]; then prepare_args+=(--revision "$NATIVE_SEEK_REVISION"); fi
if [[ -n "${NATIVE_SEEK_NEGATIVE:-}" ]]; then prepare_args+=(--negative "$NATIVE_SEEK_NEGATIVE"); fi
if [[ "${NATIVE_SEEK_INSTRUMENT:-1}" == 0 ]]; then prepare_args+=(--uninstrumented); fi
printf 'mode=%s\nsession_source=%s\nrevision=%s\nnegative=%s\nsanitizer=%s\ninstrumented=%s\n' \
  "$mode" "$session_source" "${NATIVE_SEEK_REVISION:-}" "${NATIVE_SEEK_NEGATIVE:-}" \
  "${NATIVE_PLAYBACK_SANITIZER:-}" "${NATIVE_SEEK_INSTRUMENT:-1}" > "$test_dir/mode.txt"
python3 -B Tools/NativeSeekLatencyTests/prepare.py "$session_source" "$test_dir/NativePlaybackSession.swift" ${prepare_args[@]+"${prepare_args[@]}"}
clang_flags=(); swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  "") clang_flags+=(-O2); swift_flags+=(-O) ;;
  address|thread) clang_flags+=("-fsanitize=$NATIVE_PLAYBACK_SANITIZER" -g); swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) exit 2 ;;
esac
xcrun clang "${clang_flags[@]}" -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 \
  -I "$native_test_deps/include" -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o"
xcrun swiftc "${swift_flags[@]}" -swift-version 5 -target arm64-apple-macos12 \
  -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
  iina/NativePlayback/NativePlaybackSampleGate.swift "$test_dir/NativePlaybackSession.swift" \
  Tools/NativeSeekLatencyTests/main.swift "$test_dir/decoder.o" "${native_test_libraries[@]}" \
  -Xlinker -rpath -Xlinker "$native_test_deps/lib" -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework AudioToolbox -o "$test_dir/seek-tests"
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
if [[ -n "${NATIVE_SEEK_FIXTURE:-}" ]]; then
  [[ -f "$NATIVE_SEEK_FIXTURE" && ! -L "$NATIVE_SEEK_FIXTURE" ]] || exit 2
  cp "$NATIVE_SEEK_FIXTURE" "$test_dir/long-gop.mkv"
else
case "${NATIVE_SEEK_SIZE:-160x96}" in 160x96|3840x2160) ;; *) exit 2 ;; esac
case "${NATIVE_SEEK_AUDIO:-pcm_f32le}" in pcm_f32le|aac) ;; *) exit 2 ;; esac
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i "testsrc2=size=${NATIVE_SEEK_SIZE:-160x96}:rate=30:duration=12" \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=12' \
  -c:v libx264 -preset fast -crf 18 -g 300 -keyint_min 300 -sc_threshold 0 -bf 3 \
  -pix_fmt yuv420p -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a "${NATIVE_SEEK_AUDIO:-pcm_f32le}" -ac 2 "$test_dir/long-gop.mkv"
fi
ffprobe_bin="${FFPROBE_BIN:-$(dirname "$ffmpeg_bin")/ffprobe}"
"$ffprobe_bin" -v error -select_streams v:0 -show_entries frame=key_frame,pict_type,best_effort_timestamp_time,width,height \
  -of json "$test_dir/long-gop.mkv" > "$test_dir/fixture-frames.json"
python3 -B Tools/NativeSeekLatencyTests/verify.py fixture "$test_dir/fixture-frames.json"
shasum -a 256 "$session_source" "$test_dir/NativePlaybackSession.swift" "$test_dir/decoder.o" \
  "$test_dir/seek-tests" "$test_dir/long-gop.mkv" "$test_dir/fixture-frames.json" > "$test_dir/generated.sha256"
printf 'Artifacts: %s\n' "$test_dir"
set +e
/usr/bin/perl -e 'alarm 180; exec @ARGV' "$test_dir/seek-tests" "$test_dir/long-gop.mkv" "$mode" "$test_dir/report.json" 2>&1 | tee "$test_dir/results.log"
statuses=("${PIPESTATUS[@]}")
child_status="${statuses[0]}"
tee_status="${statuses[1]}"
set -e
if [[ "${statuses[0]}" != 0 ]]; then exit "${statuses[0]}"; fi
exit "${statuses[1]}"

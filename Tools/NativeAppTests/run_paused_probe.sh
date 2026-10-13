#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-app-paused-wait.XXXXXX")"
printf 'Evidence: %s\n' "$test_dir"
source Tools/RenderTestSupport/native_dependencies.sh
prepare_native_test_dependencies
verify_native_test_runtime
inputs=(Tools/NativeAppTests/NativeAppTestDriver.swift Tools/NativeAppTests/PausedWaitProbe.swift
  Tools/NativeAppTests/HandoffWaitProbe.swift
  Tools/NativeAppTests/run_paused_probe.sh iina/NativePlayback/CYNMediaDecoder.h
  iina/NativePlayback/CYNMediaDecoder.m iina/NativePlayback/NativeSampleBufferOutput.swift
  iina/NativePlayback/NativePlaybackSampleGate.swift iina/NativePlayback/NativePlaybackSession.swift
  Tools/RenderTestSupport/native_dependencies.sh Tools/RenderTestSupport/verify_native_dependencies.py
  other/verify_playback_distribution.py)
shasum -a 256 "${inputs[@]}" > "$test_dir/source-sha256.txt"
validate_inputs() {
  local result=$?
  trap - EXIT
  shasum -a 256 -c "$test_dir/source-sha256.txt" > "$test_dir/source-validation.log" || result=1
  if [[ -f "$test_dir/generated-sha256.txt" ]]; then
    shasum -a 256 -c "$test_dir/generated-sha256.txt" > "$test_dir/generated-validation.log" || result=1
  fi
  validate_native_test_dependencies || result=1
  printf '%s\n' "$result" > "$test_dir/exit-code.txt"
  exit "$result"
}
trap validate_inputs EXIT
ffmpeg_bin="${FFMPEG_BIN:-$repo_root/deps/executable/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin -f lavfi -i 'color=red:s=160x96:r=20:d=1' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=1' -c:v libx264 -bf 2 -g 20 -pix_fmt yuv420p \
  -color_range tv -color_primaries bt709 -color_trc bt709 -colorspace bt709 -c:a aac -shortest "$test_dir/red.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin -i "$test_dir/red.mp4" -frames:v 1 -an \
  -pix_fmt nv12 -f rawvideo "$test_dir/reference.nv12"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'color=red:s=160x96:r=20:d=3' -f lavfi -i 'color=lime:s=160x96:r=20:d=3' \
  -f lavfi -i 'color=blue:s=160x96:r=20:d=3' -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=9' \
  -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0[v]' -map '[v]' -map 3:a \
  -c:v libx264 -bf 2 -g 20 -pix_fmt yuv420p -color_range tv -color_primaries bt709 \
  -color_trc bt709 -colorspace bt709 -c:a aac -shortest "$test_dir/handoff.mp4"
"$ffmpeg_bin" -hide_banner -loglevel error -nostdin -ss 4.2 -i "$test_dir/handoff.mp4" -frames:v 1 -an \
  -pix_fmt nv12 -f rawvideo "$test_dir/green.nv12"
python3 -B - "$test_dir" <<'PY'
from pathlib import Path
import json, sys
root = Path(sys.argv[1])
source = Path('Tools/NativeAppTests/NativeAppTestDriver.swift').read_text()
probe = Path('Tools/NativeAppTests/PausedWaitProbe.swift').read_text()
for name, marker in [('waitForNativePaused', 'INSERT_PAUSED_WAIT'), ('pixel', 'INSERT_PIXEL'), ('matchesReference', 'INSERT_REFERENCE')]:
    anchor = '  private ' + ('static ' if name == 'matchesReference' else '') + 'func ' + name + '('
    assert source.count(anchor) == 1
    start = source.index(anchor)
    end = source.index('\n  }', start) + len('\n  }')
    probe = probe.replace('  // ' + marker, source[start:end])
(root / 'main.swift').write_text(probe)
anchor = '    var observedSession = player.nativePlaybackSession'
assert probe.count(anchor) == 1
(root / 'negative.swift').write_text(probe.replace(anchor,
    '    guard player.nativePlaybackSession != nil else { fail(label); return }\n' + anchor, 1))
raw = (root / 'reference.nv12').read_bytes()
assert len(raw) == 160 * 96 * 3 // 2
reference = []
for y in (8, 48, 86):
    for x in (8, 80, 150):
        uv = 160 * 96 + (y // 2) * 160 + (x // 2) * 2
        reference.extend((raw[y * 160 + x], raw[uv], raw[uv + 1]))
(root / 'reference.json').write_text(json.dumps(reference))
handoff = Path('Tools/NativeAppTests/HandoffWaitProbe.swift').read_text()
for name, marker in [('waitForNativePaused', 'INSERT_PAUSED_WAIT'), ('waitForHandoffState', 'INSERT_HANDOFF_WAIT'),
                     ('pixel', 'INSERT_PIXEL'), ('matchesReference', 'INSERT_REFERENCE')]:
    anchor = '  private ' + ('static ' if name == 'matchesReference' else '') + 'func ' + name + '('
    assert source.count(anchor) == 1
    start = source.index(anchor)
    end = source.index('\n  }', start) + len('\n  }')
    handoff = handoff.replace('  // ' + marker, source[start:end])
(root / 'handoff.swift').write_text(handoff)
# Restore exactly the former fail-on-first-query behavior, not its state/pixel
# predicates. A real unavailable result must still fail this negative control.
anchor = '} else if ProcessInfo.processInfo.systemUptime >= deadline {\n          switch result {'
assert handoff.count(anchor) == 1
(root / 'one-shot.swift').write_text(handoff.replace(anchor, '} else if true {\n          switch result {', 1))
anchor = '''guard stillOwned(), player.nativePlaybackSession === session,
'''
assert handoff.count(anchor) == 2
import re
removed, count = re.subn(r'guard stillOwned\(\), player.nativePlaybackSession === session,\n\s*player.videoToolsMediaGeneration == observedGeneration else',
                         'guard !self.terminal else', handoff)
assert count == 2
(root / 'ignore-owner.swift').write_text(removed)
green = (root / 'green.nv12').read_bytes()
assert len(green) == len(raw)
green_reference = []
for y in (8, 48, 86):
    for x in (8, 80, 150):
        uv = 160 * 96 + (y // 2) * 160 + (x // 2) * 2
        green_reference.extend((green[y * 160 + x], green[uv], green[uv + 1]))
(root / 'handoff-reference.json').write_text(json.dumps({'red': reference, 'green': green_reference}))
PY
shasum -a 256 "$test_dir/main.swift" "$test_dir/negative.swift" "$test_dir/red.mp4" \
  "$test_dir/reference.nv12" "$test_dir/reference.json" > "$test_dir/generated-sha256.txt"
shasum -a 256 "$test_dir/handoff.swift" "$test_dir/handoff.mp4" "$test_dir/green.nv12" \
  "$test_dir/handoff-reference.json" "$test_dir/one-shot.swift" "$test_dir/ignore-owner.swift" >> "$test_dir/generated-sha256.txt"
set +e
xcrun clang -target arm64-apple-macos12 -fobjc-arc -fmodules -std=gnu11 -I "$native_test_deps/include" \
  -c iina/NativePlayback/CYNMediaDecoder.m -o "$test_dir/decoder.o" 2>&1 | tee "$test_dir/decoder-compile.log"
status=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${status[0]}" > "$test_dir/decoder-compile-exit-code.txt"
[[ "${status[0]}" == 0 && "${status[1]}" == 0 ]] || exit 1
shasum -a 256 "$test_dir/decoder.o" >> "$test_dir/generated-sha256.txt"
for mode in normal old-first-session old-handoff-capture handoff old-one-shot ignore-owner; do
  # Swift requires the top-level source filename main.swift in a multi-file build.
  selected="$test_dir/$mode"
  mkdir "$selected"
  if [[ "$mode" == normal ]]; then cp "$test_dir/main.swift" "$selected/main.swift"
  elif [[ "$mode" == old-first-session ]]; then cp "$test_dir/negative.swift" "$selected/main.swift"
  elif [[ "$mode" == old-one-shot ]]; then cp "$test_dir/one-shot.swift" "$selected/main.swift"
  elif [[ "$mode" == ignore-owner ]]; then cp "$test_dir/ignore-owner.swift" "$selected/main.swift"
  else cp "$test_dir/handoff.swift" "$selected/main.swift"; fi
  shasum -a 256 "$selected/main.swift" >> "$test_dir/generated-sha256.txt"
  set +e
  xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 \
    -import-objc-header iina/NativePlayback/CYNMediaDecoder.h \
    iina/NativePlayback/NativeSampleBufferOutput.swift iina/NativePlayback/NativePlaybackSampleGate.swift \
    iina/NativePlayback/NativePlaybackSession.swift "$selected/main.swift" "$test_dir/decoder.o" \
    "${native_test_libraries[@]}" -Xlinker -rpath -Xlinker "$native_test_deps/lib" \
    -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox \
    -o "$selected/probe" 2>&1 | tee "$selected/compile.log"
  status=("${PIPESTATUS[@]}")
  set -e
  printf '%s\n' "${status[0]}" > "$selected/compile-exit-code.txt"
  [[ "${status[0]}" == 0 && "${status[1]}" == 0 ]] || exit 1
  shasum -a 256 "$selected/probe" >> "$test_dir/generated-sha256.txt"
  set +e
  media="$test_dir/red.mp4"; reference="$test_dir/reference.json"
  if [[ "$mode" != normal && "$mode" != old-first-session ]]; then media="$test_dir/handoff.mp4"; reference="$test_dir/handoff-reference.json"; fi
  /usr/bin/perl -e 'alarm 25; exec @ARGV' "$selected/probe" "$media" "$reference" "$mode" \
    2>&1 | tee "$selected/results.log"
  status=("${PIPESTATUS[@]}")
  set -e
  printf '%s\n' "${status[0]}" > "$selected/exit-code.txt"
  [[ "${status[1]}" == 0 ]] || exit 1
  if [[ "$mode" == normal ]]; then
    [[ "${status[0]}" == 0 ]] || exit 1
    grep -q 'PROBE_OWNER_REPLACEMENT_REJECTED: true' "$selected/results.log"
    grep -q 'PROBE_MEDIA_GENERATION_REJECTED: true' "$selected/results.log"
  elif [[ "$mode" == old-first-session ]]; then
    [[ "${status[0]}" == 1 ]] || exit 1
    grep -q 'PROBE_FAIL: delayed_real_session' "$selected/results.log"
    grep -q 'PROBE_DELAYED: success=false failed=true' "$selected/results.log"
    grep -q 'PROBE_EXPECTED_EARLY_REJECTION: true' "$selected/results.log"
  elif [[ "$mode" == old-handoff-capture ]]; then
    [[ "${status[0]}" == 1 ]] || exit 1
    grep -q '^HANDOFF_IMMEDIATE_QUERY: unavailable$' "$selected/results.log"
    grep -q '^HANDOFF_SETTLED_REAL_STATE: true$' "$selected/results.log"
    grep -q '^HANDOFF_ORIGINAL_CAPTURE_REJECTED: true$' "$selected/results.log"
    grep -q '^HANDOFF_CLEANUP: true$' "$selected/results.log"
  elif [[ "$mode" == handoff ]]; then
    [[ "${status[0]}" == 0 ]] || exit 1
    for label in BOUNDED_READY REPLACEMENT_REJECTED GENERATION_REJECTED ROUTE_REJECTED CLEANUP; do
      grep -q "^HANDOFF_${label}: true$" "$selected/results.log"
    done
    [[ "$(grep -c '^HANDOFF_PASS: nondefault_state$' "$selected/results.log")" == 1 ]] || exit 1
    [[ "$(grep -c '^HANDOFF_FAIL: nondefault_state$' "$selected/results.log")" == 3 ]] || exit 1
  elif [[ "$mode" == old-one-shot ]]; then
    [[ "${status[0]}" == 1 ]] || exit 1
    grep -q '^HANDOFF_BOUNDED_READY: false$' "$selected/results.log"
    grep -q '^NATIVE_APP_PAUSED_WAIT: result=unavailable$' "$selected/results.log"
    [[ "$(grep -c '^HANDOFF_FAIL: nondefault_state$' "$selected/results.log")" == 1 ]] || exit 1
    ! grep -q '^HANDOFF_PASS:' "$selected/results.log"
    grep -q '^HANDOFF_CLEANUP: true$' "$selected/results.log"
  else
    [[ "${status[0]}" == 1 ]] || exit 1
    grep -q '^HANDOFF_BOUNDED_READY: true$' "$selected/results.log"
    grep -q '^HANDOFF_REPLACEMENT_REJECTED: false$' "$selected/results.log"
    [[ "$(grep -c '^HANDOFF_PASS: nondefault_state$' "$selected/results.log")" == 2 ]] || exit 1
    ! grep -q '^HANDOFF_FAIL:' "$selected/results.log"
    grep -q '^HANDOFF_CLEANUP: true$' "$selected/results.log"
  fi
  if [[ "$mode" == normal || "$mode" == old-first-session ]]; then grep -q 'PROBE_CLEANUP: true' "$selected/results.log"; fi
  if [[ "$mode" != normal && "$mode" != old-first-session ]]; then
    grep -q '^HANDOFF_WORKER_ORDERED: true$' "$selected/results.log"
  fi
done

#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
test_dir="$(mktemp -d "$repo_root/build/native-admission-tests.XXXXXX")"
sources=(iina/PlayerCore.swift Tools/NativePlaybackAdmissionTests/extract.swift
  iina/PlaybackBackend/NativePlaybackQueue.swift
  Tools/NativePlaybackAdmissionTests/Boundary.swift Tools/NativePlaybackAdmissionTests/main.swift
  Tools/NativePlaybackAdmissionTests/run.sh)
shasum -a 256 "${sources[@]}" > "$test_dir/source-before.sha256"
swift_flags=()
case "${NATIVE_PLAYBACK_SANITIZER:-}" in
  '') ;;
  address|thread) swift_flags+=("-sanitize=$NATIVE_PLAYBACK_SANITIZER" -g) ;;
  *) printf 'Unknown sanitizer\n'; exit 2 ;;
esac
ffmpeg_bin="${FFMPEG_BIN:-/opt/homebrew/bin/ffmpeg}"
"$ffmpeg_bin" -hide_banner -loglevel error -f lavfi -i 'color=c=red:s=160x96:r=10:d=1' \
  -c:v libx264 -pix_fmt yuv420p "$test_dir/fixture.mp4"
for control in positive negative; do
  work="$test_dir/$control"
  mkdir "$work"
  cp "$test_dir/fixture.mp4" "$work/fixture.mp4"
  negative=0
  if [ "$control" = negative ]; then negative=1; fi
  NATIVE_ADMISSION_NEGATIVE_CONTROL="$negative" xcrun swift Tools/NativePlaybackAdmissionTests/extract.swift \
    "$repo_root" "$work/Extracted.swift"
  xcrun swiftc ${swift_flags[@]+"${swift_flags[@]}"} -swift-version 5 -warnings-as-errors \
    iina/PlaybackBackend/NativePlaybackQueue.swift \
    "$work/Extracted.swift" Tools/NativePlaybackAdmissionTests/main.swift -o "$work/tests"
  set +e
  CHENGYING_NATIVE_PLAYBACK=1 /usr/bin/perl -e 'alarm 20; exec @ARGV' "$work/tests" "$work" \
    > "$work/results.log" 2>&1
  result=$?
  set -e
  printf '%s\n' "$result" > "$work/exit-status.txt"
  tail -n 1 "$work/results.log"
  if /usr/bin/grep -E -q 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|SUMMARY: (ThreadSanitizer|AddressSanitizer)' "$work/results.log"; then
    printf 'Unexpected sanitizer diagnostic\n'; exit 1
  fi
  if [ "$control" = positive ]; then
    test "$result" -eq 0
  else
    test "$result" -eq 1
    /usr/bin/grep -E '^FAIL:' "$work/results.log" > "$work/failures.log"
    xcrun swift -e 'import Foundation
      let lines = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map(String.init)
      let expected: Set<String> = [
        "FAIL: Disabled automatic siblings preserves native: route",
        "FAIL: Preference is captured before background inventory: route",
        "FAIL: Preference snapshot has one native owner"
      ]
      guard Set(lines) == expected && lines.count == expected.count else { fatalError("Unexpected negative-control failures: \(lines)") }
      print("PASS: Removing only the preference guard reproduces all three expected admission failures")' "$work/failures.log"
  fi
done
shasum -a 256 "${sources[@]}" > "$test_dir/source-after.sha256"
diff -u "$test_dir/source-before.sha256" "$test_dir/source-after.sha256" > "$test_dir/source-comparison.log"
printf 'Artifacts: %s\n' "$test_dir"

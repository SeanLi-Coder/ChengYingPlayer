#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-soak.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

duration="${PLAYBACK_SOAK_SECONDS:-180}"
mode="${PLAYBACK_SOAK_MODE:-hardware}"
case "$duration" in
  ''|*[!0-9]*) echo 'ERROR: PLAYBACK_SOAK_SECONDS must be an integer.' >&2; exit 2 ;;
esac
if (( duration < 60 || duration > 14400 )); then
  echo 'ERROR: PLAYBACK_SOAK_SECONDS must be between 60 and 14400.' >&2
  exit 2
fi
if [[ "$mode" != hardware && "$mode" != software ]]; then
  echo 'ERROR: PLAYBACK_SOAK_MODE must be hardware or software.' >&2
  exit 2
fi

ffmpeg="${PLAYBACK_SOAK_FFMPEG:-$project_root/deps/executable/ffmpeg}"
if [[ ! -x "$ffmpeg" || ! -f "$project_root/deps/lib/libmpv.2.dylib" || ! -f "$project_root/deps/playback-build-record/library-sha256.txt" ]]; then
  echo 'ERROR: The actual source-built playback libraries and built FFmpeg are required.' >&2
  exit 1
fi
# dav1d is now statically linked into libavcodec. Verify the executing library
# against its build record and the exact pinned decoder source, not an unused dylib.
# shellcheck source=other/playback_sources.sh
source "$project_root/other/playback_sources.sh"
expected_decoder="$(playback_source_records | awk -F '\t' '$1 == "dav1d"')"
actual_decoder="$(awk -F '\t' '$1 == "dav1d"' "$project_root/deps/playback-build-record/sources.tsv")"
if [[ -z "$expected_decoder" || "$actual_decoder" != "$expected_decoder" ]]; then
  echo 'ERROR: The compiled decoder source does not match the pinned AV1 baseline.' >&2
  exit 1
fi
(cd "$project_root/deps/lib" && shasum -a 256 -c ../playback-build-record/library-sha256.txt)
echo "Verified statically linked dav1d source: $PLAYBACK_DAV1D_VERSION"

echo 'Generating isolated 3840x2160 H.264 and HEVC Main10 fixtures.'
"$ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'testsrc2=size=3840x2160:rate=24' -t 6 -an \
  -c:v libx264 -preset ultrafast -crf 28 -threads 4 -pix_fmt yuv420p \
  -g 24 -movflags +faststart "$test_dir/h264.mp4"
"$ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'testsrc2=size=3840x2160:rate=24' -t 6 -an \
  -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p10le \
  -x265-params 'log-level=error:pools=4:frame-threads=2:keyint=24' \
  -tag:v hvc1 -movflags +faststart "$test_dir/hevc-main10.mp4"

xcrun clang -std=c11 -Wall -Wextra -Werror -O2 \
  -I "$project_root/deps/include" \
  "$project_root/Tools/PlaybackSoakTests/main.c" \
  "$project_root/deps/lib/libmpv.2.dylib" \
  -framework OpenGL -framework CoreFoundation \
  -Wl,-rpath,"$project_root/deps/lib" \
  -o "$test_dir/PlaybackSoakTests"

# A separate process enforces the deadline even if libmpv or a driver deadlocks.
# Nothing is inherited from a user's mpv configuration or media library.
bash "$project_root/Tools/RenderTestSupport/run_with_capability_policy.sh" "$mode" 'Actual 4K OpenGL render soak' /usr/bin/perl -e '
  use strict;
  use warnings;
  my ($seconds, @command) = @ARGV;
  my $pid = fork();
  defined($pid) or die "Unable to fork soak watchdog\n";
  if ($pid == 0) { exec @command; die "Unable to execute soak test\n"; }
  $SIG{ALRM} = sub {
    warn "FAIL: External playback soak deadline exceeded\n";
    kill "KILL", $pid;
    waitpid($pid, 0);
    exit 124;
  };
  alarm($seconds + 90);
  waitpid($pid, 0);
  my $status = $?;
  alarm(0);
  if ($status & 127) { warn "FAIL: Playback soak terminated by signal " . ($status & 127) . "\n"; exit 1; }
  exit($status >> 8);
' "$duration" "$test_dir/PlaybackSoakTests" \
  "$test_dir/h264.mp4" "$test_dir/hevc-main10.mp4" "$duration" "$mode" \
  "$project_root/deps/lib/libavcodec.61.dylib"

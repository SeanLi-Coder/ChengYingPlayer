#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-video-viewport-live.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mode="${VIDEO_VIEWPORT_LIVE_MODE:-hardware}"
if [[ "$mode" != hardware && "$mode" != software ]]; then
  echo 'ERROR: VIDEO_VIEWPORT_LIVE_MODE must be hardware or software.' >&2
  exit 2
fi
ffmpeg="$project_root/deps/executable/ffmpeg"
if [[ ! -x "$ffmpeg" || ! -f "$project_root/deps/lib/libmpv.2.dylib" ]]; then
  echo 'ERROR: The actual shipped playback libraries and source-built FFmpeg are required.' >&2
  exit 1
fi

echo 'Generating an isolated 4K viewport reference video.'
"$ffmpeg" -hide_banner -loglevel error -nostdin -f lavfi \
  -i 'color=c=white:size=3840x2160:rate=24,drawbox=x=1680:y=960:w=480:h=240:color=red:t=fill' \
  -t 6 -an -c:v libx264 -preset ultrafast -crf 18 -threads 4 -pix_fmt yuv420p \
  -g 24 -movflags +faststart "$test_dir/reference.mp4"

# Mechanical extraction executes the production model and bridge verbatim. The
# strict landmarks deliberately fail if production integration is reorganized.
/usr/bin/perl -0777 -ne '
  my ($model) = /^(struct VideoToolsViewport:.*?)^struct VideoToolsPlayerSnapshot \{/ms;
  my ($bridge) = /^(extension PlayerCore \{.*?)^  var videoToolsLoopRange:/ms;
  defined($model) && defined($bridge) or die "Production viewport extraction landmarks changed\n";
  print "import Foundation\n", $model, $bridge, "}\n";
' "$project_root/iina/VideoTools/VideoToolsPlayerBridge.swift" > "$test_dir/ProductionViewport.swift"

xcrun clang -fobjc-arc -Wno-deprecated-declarations -Wall -Wextra -Werror -O2 \
  -I "$project_root/deps/include" \
  -c "$project_root/Tools/VideoViewportTests/Live/Renderer.m" \
  -o "$test_dir/Renderer.o"
xcrun swiftc -import-objc-header "$project_root/Tools/VideoViewportTests/Live/Renderer.h" \
  -o "$test_dir/VideoViewportLiveTests" \
  "$project_root/iina/MPVOption.swift" \
  "$project_root/iina/VideoTools/VideoToolsShortcuts.swift" \
  "$test_dir/ProductionViewport.swift" \
  "$project_root/Tools/VideoViewportTests/Live/Boundary.swift" \
  "$project_root/Tools/VideoViewportTests/Live/main.swift" \
  "$test_dir/Renderer.o" "$project_root/deps/lib/libmpv.2.dylib" \
  -framework OpenGL -framework AppKit -Xlinker -rpath -Xlinker "$project_root/deps/lib"

# An external watchdog also bounds a driver or player deadlock.
/usr/bin/perl -e '
  use strict;
  use warnings;
  my $pid = fork();
  defined($pid) or die "Unable to fork viewport watchdog\n";
  if ($pid == 0) { exec @ARGV; die "Unable to execute viewport test\n"; }
  $SIG{ALRM} = sub {
    warn "FAIL: External viewport deadline exceeded\n";
    kill "KILL", $pid;
    waitpid($pid, 0);
    exit 124;
  };
  alarm(90);
  waitpid($pid, 0);
  my $status = $?;
  alarm(0);
  if ($status & 127) { warn "FAIL: Viewport test terminated by signal " . ($status & 127) . "\n"; exit 1; }
  exit($status >> 8);
' "$test_dir/VideoViewportLiveTests" "$test_dir/reference.mp4" "$mode"

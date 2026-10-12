#!/bin/bash
set -euo pipefail

# Build an unpatched, hardware-only AV1 reference CLI, not a player dependency.
# Usage: bash Tools/AV1PlaybackTests/build_reference.sh --output NEW_DIRECTORY
#        [--source-cache DIRECTORY]
# The output must not exist (including a dangling symlink). Its parent must
# already exist. Failure preserves logs there; reruns require a new output path.
# No app bundles, system installation, or project media binaries are created.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=other/third_party_sources.sh
source "$ROOT/other/third_party_sources.sh"

fail() { printf 'Reference FFmpeg build: %s\n' "$*" >&2; exit 2; }
OUTPUT=""
CACHE="${SOURCE_CACHE_DIR:-$ROOT/deps/sources}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 && -n "$2" && -z "$OUTPUT" ]] || fail "Expected one --output directory."
      OUTPUT="$2"; shift 2 ;;
    --source-cache)
      [[ $# -ge 2 && -n "$2" ]] || fail "Expected a --source-cache directory."
      CACHE="$2"; shift 2 ;;
    --help)
      printf '%s\n' 'Usage: build_reference.sh --output NEW_DIRECTORY [--source-cache DIRECTORY]' \
        'Builds a native macOS FFmpeg reference CLI at NEW_DIRECTORY/bin/ffmpeg.' \
        'The output must not exist; its parent must already exist. Failure preserves logs.'
      exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -n "$OUTPUT" ]] || fail "An explicit --output directory is required."
[[ "$(uname -s)" == Darwin ]] || fail "This reference requires macOS VideoToolbox."
[[ "$FFMPEG_VERSION" == 9.0.1 ]] || fail "This diagnostic is pinned to official FFmpeg 9.0.1."
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "Refusing to overwrite an existing output."
OUTPUT_NAME="$(basename "$OUTPUT")"
[[ "$OUTPUT_NAME" != . && "$OUTPUT_NAME" != .. && "$OUTPUT_NAME" != / ]] || fail "Unsafe output path."
OUTPUT_PARENT="$(cd "$(dirname "$OUTPUT")" && pwd -P)" || fail "Output parent does not exist."
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail "Refusing to overwrite a resolved existing output."

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) DEPLOYMENT_TARGET=12.0 ;;
  x86_64) DEPLOYMENT_TARGET=10.15 ;;
  *) fail "Unsupported native architecture: $ARCH" ;;
esac
JOBS="$(sysctl -n hw.logicalcpu)"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "Invalid native build parallelism."
[[ "$JOBS" -le 4 ]] || JOBS=4
SDK="$(xcrun --show-sdk-path)"
mkdir "$OUTPUT"
mkdir "$OUTPUT/bin"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chengying-av1-reference.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -f "$WORK/build/ffbuild/config.log" ]]; then
    cp "$WORK/build/ffbuild/config.log" "$OUTPUT/ffbuild-config.log" || status=1
  fi
  if [[ "$WORK" == "${TMPDIR:-/tmp}/chengying-av1-reference."* && -d "$WORK" && ! -L "$WORK" ]]; then
    rm -rf -- "$WORK" || status=1
  else
    printf '%s\n' 'Refusing cleanup of an unexpected reference workspace.' >&2
    status=1
  fi
  if [[ "$status" -ne 0 ]]; then
    printf 'Reference build failed; diagnostic output retained at %s\n' "$OUTPUT" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Building official FFmpeg %s reference (%s).\n' "$FFMPEG_VERSION" "$ARCH"
ARCHIVE="$(fetch_verified_source ffmpeg "$CACHE")"
# Keep the independent source check explicit even when the shared helper reuses
# a cached archive. Never apply the player's playback or editing patches here.
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$FFMPEG_SOURCE_SHA256" ]] || fail "Verified archive changed before extraction."
{
  printf 'component=official-ffmpeg-reference\nversion=%s\nsource_url=%s\nsource_sha256=%s\n' \
    "$FFMPEG_VERSION" "$FFMPEG_SOURCE_URL" "$ACTUAL_SHA"
  printf 'patches=none\narchitecture=%s\ndeployment_target=%s\n' "$ARCH" "$DEPLOYMENT_TARGET"
  printf '%s\n' 'decoder=native-av1-hardware-only' 'network=disabled' 'purpose=diagnostic-only'
  sw_vers
  xcrun clang --version
} > "$OUTPUT/metadata.txt"
tar -xf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/ffmpeg-$FFMPEG_VERSION"
mkdir "$WORK/build"
cd "$WORK/build"

# The color source is only a positive control for wrapped_avframe/null output;
# it prevents an output/filter configuration fault from looking like a VT fault.
# av1 is FFmpeg's native hardware wrapper, not libdav1d or libaom software decode.
"$SOURCE/configure" \
  --prefix="$OUTPUT" --cc="$(xcrun --find clang)" --sysroot="$SDK" --arch="$ARCH" --target-os=darwin \
  --host-cflags="--sysroot=$SDK" --host-ldflags="--sysroot=$SDK" \
  --extra-cflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
  --extra-ldflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
  --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug \
  --disable-shared --enable-static --disable-avdevice --disable-swresample \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg \
  --enable-videotoolbox --enable-decoder=av1 --enable-hwaccel=av1_videotoolbox \
  --enable-parser=av1 --enable-demuxer=ivf --enable-muxer=null \
  --enable-encoder=wrapped_avframe --enable-protocol=file,pipe \
  --enable-filter=color,hwdownload,format,scale,null \
  > "$OUTPUT/configure.log" 2>&1
cp config.h config_components.h "$OUTPUT/"

require_config() {
  grep -Fqx "#define $1 $2" "$OUTPUT/config_components.h" "$OUTPUT/config.h" || \
    fail "Required reference configuration is missing: $1=$2"
}
require_config CONFIG_AV1_DECODER 1
require_config CONFIG_AV1_VIDEOTOOLBOX_HWACCEL 1
require_config CONFIG_LIBDAV1D_DECODER 0
require_config CONFIG_LIBAOM_AV1_DECODER 0
require_config CONFIG_NETWORK 0
require_config CONFIG_IVF_DEMUXER 1
require_config CONFIG_NULL_MUXER 1
require_config CONFIG_WRAPPED_AVFRAME_ENCODER 1
require_config CONFIG_HWDOWNLOAD_FILTER 1
require_config CONFIG_FORMAT_FILTER 1
require_config CONFIG_COLOR_FILTER 1

printf '%s\n' 'Compiling minimal AV1 reference CLI.'
make -j"$JOBS" ffmpeg > "$OUTPUT/build.log" 2>&1
cp ffmpeg "$OUTPUT/bin/ffmpeg"
"$OUTPUT/bin/ffmpeg" -version > "$OUTPUT/version.txt"
otool -L "$OUTPUT/bin/ffmpeg" > "$OUTPUT/dependencies.txt"
while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *) fail "Non-system dynamic dependency in the reference CLI: $dependency" ;;
  esac
done < <(otool -L "$OUTPUT/bin/ffmpeg" | tail -n +2 | awk '{print $1}')

"$OUTPUT/bin/ffmpeg" -hide_banner -nostdin -v verbose -xerror \
  -filter_complex 'color=size=16x16:rate=1' -frames:v 1 -c:v wrapped_avframe -f null - \
  > "$OUTPUT/null-output-control.log" 2>&1
printf '%s\n' 'null_output_control_exit=0' >> "$OUTPUT/metadata.txt"
shasum -a 256 "$OUTPUT/bin/ffmpeg" > "$OUTPUT/ffmpeg.sha256"
printf 'Reference CLI ready: %s/bin/ffmpeg\n' "$OUTPUT"

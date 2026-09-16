#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DESTINATION="${1:-}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"

# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"

if [[ -z "$DESTINATION" ]]; then
  echo "Usage: $0 <application-resources-directory>" >&2
  exit 2
fi

for command_name in curl install shasum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 2
  fi
done

FFMPEG_ARCHIVE="$(fetch_verified_source ffmpeg "$SOURCE_CACHE_DIR")"
X264_ARCHIVE="$(fetch_verified_source x264 "$SOURCE_CACHE_DIR")"
X265_ARCHIVE="$(fetch_verified_source x265 "$SOURCE_CACHE_DIR")"
FREETYPE_ARCHIVE="$(fetch_verified_source freetype "$SOURCE_CACHE_DIR")"
HARFBUZZ_ARCHIVE="$(fetch_verified_source harfbuzz "$SOURCE_CACHE_DIR")"
FRIBIDI_ARCHIVE="$(fetch_verified_source fribidi "$SOURCE_CACHE_DIR")"
UNIBREAK_ARCHIVE="$(fetch_verified_source libunibreak "$SOURCE_CACHE_DIR")"
LIBASS_ARCHIVE="$(fetch_verified_source libass "$SOURCE_CACHE_DIR")"
PYTHON_ARCHIVE="$(fetch_verified_source cpython "$SOURCE_CACHE_DIR")"
PYINSTALLER_ARCHIVE="$(fetch_verified_source pyinstaller "$SOURCE_CACHE_DIR")"
ALTGRAPH_ARCHIVE="$(fetch_verified_source altgraph "$SOURCE_CACHE_DIR")"
MACHOLIB_ARCHIVE="$(fetch_verified_source macholib "$SOURCE_CACHE_DIR")"
PACKAGING_ARCHIVE="$(fetch_verified_source packaging "$SOURCE_CACHE_DIR")"
PYINSTALLER_HOOKS_ARCHIVE="$(fetch_verified_source pyinstaller-hooks-contrib "$SOURCE_CACHE_DIR")"
SETUPTOOLS_ARCHIVE="$(fetch_verified_source setuptools "$SOURCE_CACHE_DIR")"

LEGAL_DIR="$DESTINATION/Legal"
mkdir -p "$LEGAL_DIR"

install -m 644 "$PROJECT_ROOT/LICENSE" "$LEGAL_DIR/ChengYingPlayer-GPLv3.txt"
install -m 644 "$PROJECT_ROOT/NOTICE.md" "$LEGAL_DIR/ChengYingPlayer-NOTICE.md"
install -m 644 "$PROJECT_ROOT/Legal/THIRD_PARTY_NOTICES.md" "$LEGAL_DIR/THIRD_PARTY_NOTICES.md"
write_third_party_source_manifest "$LEGAL_DIR/SOURCE_MANIFEST.txt"

tar -xOf "$FFMPEG_ARCHIVE" "ffmpeg-$FFMPEG_VERSION/COPYING.GPLv3" \
  > "$LEGAL_DIR/FFmpeg-COPYING.GPLv3.txt"
tar -xOf "$FFMPEG_ARCHIVE" "ffmpeg-$FFMPEG_VERSION/LICENSE.md" \
  > "$LEGAL_DIR/FFmpeg-LICENSE.md"
tar -xOf "$X264_ARCHIVE" "x264-$X264_COMMIT/COPYING" \
  > "$LEGAL_DIR/x264-COPYING.txt"
tar -xOf "$X265_ARCHIVE" "x265_$X265_VERSION/COPYING" \
  > "$LEGAL_DIR/x265-COPYING.txt"
tar -xOf "$FREETYPE_ARCHIVE" "freetype-$FREETYPE_VERSION/docs/FTL.TXT" \
  > "$LEGAL_DIR/FreeType-FTL.txt"
tar -xOf "$FREETYPE_ARCHIVE" "freetype-$FREETYPE_VERSION/docs/GPLv2.TXT" \
  > "$LEGAL_DIR/FreeType-GPLv2.txt"
tar -xOf "$HARFBUZZ_ARCHIVE" "harfbuzz-$HARFBUZZ_VERSION/COPYING" \
  > "$LEGAL_DIR/HarfBuzz-COPYING.txt"
tar -xOf "$FRIBIDI_ARCHIVE" "fribidi-$FRIBIDI_VERSION/COPYING" \
  > "$LEGAL_DIR/FriBidi-COPYING.txt"
tar -xOf "$UNIBREAK_ARCHIVE" "libunibreak-$UNIBREAK_VERSION/LICENCE" \
  > "$LEGAL_DIR/libunibreak-LICENCE.txt"
tar -xOf "$LIBASS_ARCHIVE" "libass-$LIBASS_VERSION/COPYING" \
  > "$LEGAL_DIR/libass-COPYING.txt"
tar -xOf "$PYTHON_ARCHIVE" "Python-$PYTHON_VERSION/LICENSE" \
  > "$LEGAL_DIR/CPython-LICENSE.txt"
tar -xOf "$PYINSTALLER_ARCHIVE" "pyinstaller-$PYINSTALLER_VERSION/COPYING.txt" \
  > "$LEGAL_DIR/PyInstaller-COPYING.txt"
tar -xOf "$PYINSTALLER_ARCHIVE" "pyinstaller-$PYINSTALLER_VERSION/bootloader/waflib/LICENSE" \
  > "$LEGAL_DIR/PyInstaller-waflib-LICENSE.txt"
tar -xOf "$PYINSTALLER_ARCHIVE" "pyinstaller-$PYINSTALLER_VERSION/bootloader/zlib/LICENSE" \
  > "$LEGAL_DIR/PyInstaller-zlib-LICENSE.txt"
tar -xOf "$ALTGRAPH_ARCHIVE" "altgraph-$ALTGRAPH_VERSION/LICENSE" \
  > "$LEGAL_DIR/altgraph-LICENSE.txt"
tar -xOf "$MACHOLIB_ARCHIVE" "macholib-$MACHOLIB_VERSION/LICENSE" \
  > "$LEGAL_DIR/macholib-LICENSE.txt"
tar -xOf "$PACKAGING_ARCHIVE" "packaging-$PACKAGING_VERSION/LICENSE" \
  > "$LEGAL_DIR/packaging-LICENSE.txt"
tar -xOf "$PACKAGING_ARCHIVE" "packaging-$PACKAGING_VERSION/LICENSE.APACHE" \
  > "$LEGAL_DIR/packaging-LICENSE.APACHE.txt"
tar -xOf "$PACKAGING_ARCHIVE" "packaging-$PACKAGING_VERSION/LICENSE.BSD" \
  > "$LEGAL_DIR/packaging-LICENSE.BSD.txt"
tar -xOf "$PYINSTALLER_HOOKS_ARCHIVE" "pyinstaller_hooks_contrib-$PYINSTALLER_HOOKS_VERSION/LICENSE" \
  > "$LEGAL_DIR/PyInstaller-hooks-contrib-LICENSE.txt"
tar -xOf "$SETUPTOOLS_ARCHIVE" "setuptools-$SETUPTOOLS_VERSION/LICENSE" \
  > "$LEGAL_DIR/setuptools-LICENSE.txt"

DOWNLOAD_CENTER_LEGAL="$PROJECT_ROOT/deps/download-center/DownloadCenter.app/Contents/Resources/Legal"
read -r -a BUILD_ARCHS <<< "${ARCHS:-arm64}"
if [[ "${#BUILD_ARCHS[@]}" == "1" && "${BUILD_ARCHS[0]}" == "x86_64" ]]; then
  # No ARM-only runtime is included in an Intel application build.
  if [[ -d "$LEGAL_DIR/DownloadCenter" ]]; then
    rm -rf -- "$LEGAL_DIR/DownloadCenter"
  fi
else
  if [[ ! -s "$DOWNLOAD_CENTER_LEGAL/runtime-artifacts.json" || ! -s "$DOWNLOAD_CENTER_LEGAL/RednoteDownloader-MIT-LICENSE.txt" ]]; then
    echo "Build the download center and its pinned runtime notices before packaging." >&2
    exit 1
  fi
  ditto --noqtn "$DOWNLOAD_CENTER_LEGAL" "$LEGAL_DIR/DownloadCenter"
fi

for legal_file in "$LEGAL_DIR"/*; do
  if [[ -f "$legal_file" && ! -s "$legal_file" ]]; then
    echo "Legal notice is empty: $legal_file" >&2
    exit 1
  fi
done

echo "Legal notices are ready in $LEGAL_DIR"

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
deps_dir="${1:-$project_root/deps}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-playback-build-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# shellcheck source=other/playback_sources.sh
source "$project_root/other/playback_sources.sh"

while IFS= read -r name; do
  [[ -f "$deps_dir/lib/$name" ]] || { echo "Missing playback library: $name" >&2; exit 1; }
  lipo "$deps_dir/lib/$name" -verify_arch arm64
  codesign --verify --strict "$deps_dir/lib/$name"
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/* | /usr/lib/*) ;;
      @rpath/*.dylib)
        playback_library_names | grep -Fxq "${dependency#@rpath/}" || {
          echo "Untracked playback dependency: $dependency" >&2; exit 1;
        }
        ;;
      *) echo "Non-bundled playback dependency: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$deps_dir/lib/$name" | tail -n +2 | awk '{print $1}')
done < <(playback_library_names)

(
  cd "$deps_dir/lib"
  shasum -a 256 -c "$deps_dir/playback-build-record/library-sha256.txt"
)

xcrun clang -std=c11 -Wall -Wextra -Werror -O2 \
  -I "$deps_dir/include" "$project_root/Tools/PlaybackBuildTests/main.c" \
  "$deps_dir/lib/libmpv.2.dylib" "$deps_dir/lib/libavcodec.61.dylib" \
  "$deps_dir/lib/libavformat.61.dylib" "$deps_dir/lib/libavutil.59.dylib" \
  "$deps_dir/lib/libavfilter.10.dylib" -Wl,-rpath,"$deps_dir/lib" \
  -o "$test_dir/PlaybackBuildTests"
python3 "$project_root/Tools/PlaybackBuildTests/extract_options.py" > "$test_dir/production-options.tsv"
"$test_dir/PlaybackBuildTests" "$test_dir/production-options.tsv"

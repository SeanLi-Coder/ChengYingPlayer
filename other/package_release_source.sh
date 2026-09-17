#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="${1:-}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"
SOURCE_REF="${SOURCE_REF:-HEAD}"
HELPER_PYTHON="${HELPER_PYTHON:-python3}"

# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Usage: $0 <output.tar.gz>" >&2
  exit 2
fi
if [[ -e "$OUTPUT_PATH" || -L "$OUTPUT_PATH" ]]; then
  echo "Refusing to overwrite an existing source archive." >&2
  exit 2
fi
"$HELPER_PYTHON" "$SCRIPT_DIR/verify_playback_distribution.py" "$PROJECT_ROOT/deps"

for command_name in curl git install shasum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 2
  fi
done

COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify "$SOURCE_REF^{commit}")"
if [[ "$COMMIT" != "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" ]] ||
   ! git -C "$PROJECT_ROOT" diff --quiet HEAD --; then
  echo "Source packaging requires the current HEAD and a clean tracked source tree." >&2
  exit 2
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
OUTPUT_PATH="$OUTPUT_DIR/$(basename "$OUTPUT_PATH")"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.chengying-release-source.XXXXXX")"
PACKAGE_NAME="ChengYingPlayer-$COMMIT"
PACKAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
SOURCE_DIR="$PACKAGE_DIR/third-party-sources"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && "$WORK_DIR" == "$OUTPUT_DIR"/.chengying-release-source.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$PACKAGE_DIR" "$SOURCE_DIR" "$(dirname "$OUTPUT_PATH")"
git -C "$PROJECT_ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$PACKAGE_DIR"

while IFS=$'\t' read -r component _version filename _url _expected_sha256; do
  source_path="$(fetch_verified_source "$component" "$SOURCE_CACHE_DIR")"
  install -m 644 "$source_path" "$SOURCE_DIR/$filename"
done < <(third_party_source_records)

"$HELPER_PYTHON" "$PROJECT_ROOT/Tools/DownloaderHelper/source_materials.py" \
  package "$SOURCE_DIR/download-runtime" --cache "$SOURCE_CACHE_DIR/download-runtime"
ditto --noqtn "$PROJECT_ROOT/deps/playback-build-record" "$PACKAGE_DIR/playback-build-record"

write_third_party_source_manifest "$SOURCE_DIR/SOURCE_MANIFEST.txt"
install -m 644 "$PROJECT_ROOT/Tools/DownloaderHelper/runtime-artifacts.json" \
  "$SOURCE_DIR/DownloadCenter-WHEEL-MANIFEST.json"
{
  printf '%s\n' "ChengYingPlayer release source package"
  printf '%s\n' ""
  printf 'Release source commit: %s\n' "$COMMIT"
  printf '%s\n' "The application source and build scripts are in this directory."
  printf '%s\n' "Verified source archives for the playback stack, Swift packages, FFmpeg tools, image codec, frozen helper runtime and build dependencies are in third-party-sources/."
  printf '%s\n' "The download center preserves its upstream MIT source under Tools/DownloaderHelper/vendor/rednote/."
  printf '%s\n' "DownloadCenter-WHEEL-MANIFEST.json identifies pinned runtime wheels. Their verified sources and runtime source manifest are in third-party-sources/download-runtime/."
  printf '%s\n' "playback-build-record/ contains the exact source, configuration, toolchain and library checksums for this release build. The App inside the matching Apple-Silicon.dmg is the installable artifact."
  printf '%s\n' "Playback patches in other/patches/ are applied automatically, in locked order, by other/build_playback_libraries.sh; playback-build-record/ preserves their exact bytes and original/modified source hashes."
  # Expand PWD when the recipient follows these instructions, not during packaging.
  # shellcheck disable=SC2016
  printf '%s\n' 'To reuse the included playback source archives, run SOURCE_CACHE_DIR="$PWD/third-party-sources" bash other/build_playback_libraries.sh from this extracted package directory.'
  printf '%s\n' "See NOTICE.md and Legal/THIRD_PARTY_NOTICES.md before building or redistributing a binary."
} > "$PACKAGE_DIR/RELEASE_SOURCE_README.txt"

tar -czf "$WORK_DIR/release-source.tar.gz" -C "$WORK_DIR" "$PACKAGE_NAME"
tar -tzf "$WORK_DIR/release-source.tar.gz" >/dev/null
# Publish without a race between the initial existence check and the completed archive.
# The temporary archive is complete; a concurrently created destination is never replaced.
"$HELPER_PYTHON" -c 'import os, sys; os.link(sys.argv[1], sys.argv[2])' \
  "$WORK_DIR/release-source.tar.gz" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="${1:-}"
SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-$PROJECT_ROOT/deps/sources}"
SOURCE_REF="${SOURCE_REF:-HEAD}"

# shellcheck source=other/third_party_sources.sh
source "$SCRIPT_DIR/third_party_sources.sh"

if [[ -z "$OUTPUT_PATH" ]]; then
  echo "Usage: $0 <output.tar.gz>" >&2
  exit 2
fi

for command_name in curl git install shasum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command_name" >&2
    exit 2
  fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-release-source.XXXXXX")"
COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify "$SOURCE_REF^{commit}")"
PACKAGE_NAME="ChengYingPlayer-$COMMIT"
PACKAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
SOURCE_DIR="$PACKAGE_DIR/third-party-sources"

cleanup() {
  if [[ -n "${WORK_DIR:-}" && "$WORK_DIR" == "${TMPDIR:-/tmp}"/chengying-release-source.* ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$PACKAGE_DIR" "$SOURCE_DIR" "$(dirname "$OUTPUT_PATH")"
git -C "$PROJECT_ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$PACKAGE_DIR"

while IFS=$'\t' read -r component version filename url expected_sha256; do
  source_path="$(fetch_verified_source "$component" "$SOURCE_CACHE_DIR")"
  install -m 644 "$source_path" "$SOURCE_DIR/$filename"
done < <(third_party_source_records)

write_third_party_source_manifest "$SOURCE_DIR/SOURCE_MANIFEST.txt"
{
  printf '%s\n' "ChengYingPlayer release source package"
  printf '%s\n' ""
  printf 'Release source commit: %s\n' "$COMMIT"
  printf '%s\n' "The application source and build scripts are in this directory."
  printf '%s\n' "Verified source archives for the added FFmpeg tools, frozen helper runtime, and helper build dependencies are in third-party-sources/."
  printf '%s\n' "This source-only release does not distribute the playback dylibs used by CI and is not an offer for those upstream binaries."
  printf '%s\n' "See NOTICE.md and Legal/THIRD_PARTY_NOTICES.md before building or redistributing a binary."
} > "$PACKAGE_DIR/RELEASE_SOURCE_README.txt"

tar -czf "$OUTPUT_PATH" -C "$WORK_DIR" "$PACKAGE_NAME"
echo "$OUTPUT_PATH"

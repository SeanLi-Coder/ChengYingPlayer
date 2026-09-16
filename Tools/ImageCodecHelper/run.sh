#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="${IMAGE_CODEC_HELPER:-$PROJECT_ROOT/deps/executable/chengying-image-codec}"
if [[ ! -x "$HELPER" ]]; then
  echo "Build the image codec with other/build_image_codec.sh before testing." >&2
  exit 2
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chengying-image-codec-tests.XXXXXX")"
cleanup() {
  if [[ "$WORK_DIR" == "${TMPDIR:-/tmp}"/chengying-image-codec-tests.* ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT
swiftc "$SCRIPT_DIR/tests.swift" -o "$WORK_DIR/checks"
"$WORK_DIR/checks" "$HELPER" "$WORK_DIR"

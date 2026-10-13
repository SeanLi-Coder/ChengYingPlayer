#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
test_root="$(mktemp -d "$PWD/build/playback-file-tags.XXXXXX")"
printf 'Test evidence: %s\n' "$test_root"
sources=(iina/PlaybackFileTags.swift iina/PlaylistFileMetadata.swift Tools/PlaybackFileTagTests/main.swift)
shasum -a 256 "${sources[@]}" > "$test_root/sources-before.sha256"
flags=(-Onone)
if [[ "${PLAYBACK_FILE_TAG_SANITIZER:-}" != "" ]]; then
  flags+=("-sanitize=$PLAYBACK_FILE_TAG_SANITIZER")
fi
xcrun swiftc -DPLAYBACK_FILE_TAG_TESTING "${flags[@]}" "${sources[@]}" -o "$test_root/verify"
"$test_root/verify" "$test_root/fixtures" | tee "$test_root/result.txt"
shasum -a 256 -c "$test_root/sources-before.sha256"

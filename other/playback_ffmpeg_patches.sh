#!/bin/bash

# FFmpeg uses separate locks so mpv-only source regressions retain their inputs.
apply_playback_ffmpeg_patches() (
  set -euo pipefail
  local source_root="$1" record_dir="$2/ffmpeg-av1-backport"
  local patch_dir name component filename origin expected actual relative
  patch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/patches" && pwd)"
  (
    cd "$source_root"
    shasum -a 256 -c "$patch_dir/playback-ffmpeg-before-sha256.txt"
  )
  # A new source must be genuinely absent, not an empty or dangling substitute.
  printf '%s\n' ffmpeg-7.1.5/libavcodec/videotoolbox_av1.c | \
    cmp -s - "$patch_dir/playback-ffmpeg-added-files.txt" || {
    echo 'Unexpected FFmpeg added-source lock.' >&2; exit 1;
  }
  while IFS= read -r relative; do
    if [[ -e "$source_root/$relative" || -L "$source_root/$relative" ]]; then
      echo "FFmpeg added source already exists: $relative" >&2
      exit 1
    fi
  done < "$patch_dir/playback-ffmpeg-added-files.txt"
  mkdir -p "$record_dir/patches" "$record_dir/patched-sources"
  while IFS=$'\t' read -r name component filename origin expected; do
    actual="$(shasum -a 256 "$patch_dir/$filename" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
      echo "FFmpeg playback patch checksum mismatch: $name" >&2; exit 1;
    }
    echo "Applying verified FFmpeg playback patch: $name ($origin)"
    patch --batch --forward --fuzz=0 -d "$source_root/$component" -p1 -i "$patch_dir/$filename"
    cp "$patch_dir/$filename" "$record_dir/patches/$filename"
  done < "$patch_dir/playback-ffmpeg-patches.tsv"
  (
    cd "$source_root"
    shasum -a 256 -c "$patch_dir/playback-ffmpeg-after-sha256.txt"
  )
  while read -r expected relative; do
    mkdir -p "$record_dir/patched-sources/$(dirname "$relative")"
    cp "$source_root/$relative" "$record_dir/patched-sources/$relative"
  done < "$patch_dir/playback-ffmpeg-after-sha256.txt"
  cp "$patch_dir/playback-ffmpeg-patches.tsv" "$record_dir/patches.tsv"
  cp "$patch_dir/playback-ffmpeg-before-sha256.txt" "$record_dir/patch-before-sha256.txt"
  cp "$patch_dir/playback-ffmpeg-after-sha256.txt" "$record_dir/patch-after-sha256.txt"
  cp "$patch_dir/playback-ffmpeg-added-files.txt" "$record_dir/patch-added-files.txt"
)

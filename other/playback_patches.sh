#!/bin/bash

# Only checked-in patch locks are interpreted. Build records are outputs,
# never scripts or inputs to the patch application step.
apply_playback_patches() (
  set -euo pipefail
  local source_root="$1" record_dir="$2"
  local patch_dir
  patch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/patches" && pwd)"
  local name component filename origin expected actual relative
  (
    cd "$source_root"
    shasum -a 256 -c "$patch_dir/playback-before-sha256.txt"
  )
  mkdir -p "$record_dir/patches" "$record_dir/patched-sources"
  while IFS=$'\t' read -r name component filename origin expected; do
    actual="$(shasum -a 256 "$patch_dir/$filename" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      echo "Playback patch checksum mismatch: $name" >&2
      exit 1
    fi
    echo "Applying verified playback patch: $name ($origin)"
    patch --batch --forward --fuzz=0 -d "$source_root/$component" -p1 -i "$patch_dir/$filename"
    cp "$patch_dir/$filename" "$record_dir/patches/$filename"
  done < "$patch_dir/playback-patches.tsv"
  (
    cd "$source_root"
    shasum -a 256 -c "$patch_dir/playback-after-sha256.txt"
  )
  while read -r expected relative; do
    mkdir -p "$record_dir/patched-sources/$(dirname "$relative")"
    cp "$source_root/$relative" "$record_dir/patched-sources/$relative"
  done < "$patch_dir/playback-after-sha256.txt"
  cp "$patch_dir/playback-patches.tsv" "$record_dir/patches.tsv"
  cp "$patch_dir/playback-before-sha256.txt" "$record_dir/patch-before-sha256.txt"
  cp "$patch_dir/playback-after-sha256.txt" "$record_dir/patch-after-sha256.txt"
)

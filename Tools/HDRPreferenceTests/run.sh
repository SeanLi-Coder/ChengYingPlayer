#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="${HDR_PREFERENCE_SOURCE_ROOT:-$project_root}"
hdr_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/chengying-hdr-preferences.XXXXXX")"
trap 'rm -rf -- "$hdr_test_dir"' EXIT

source_file="$project_root/Tools/HDRPreferenceTests/main.swift"
xcrun swiftc -target x86_64-apple-macos10.15 -typecheck "$source_file"
xcrun swiftc -o "$hdr_test_dir/HDRPreferenceTests" "$source_file"
"$hdr_test_dir/HDRPreferenceTests" "$source_root"

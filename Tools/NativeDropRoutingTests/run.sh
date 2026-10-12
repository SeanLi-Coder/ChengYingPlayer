#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d "$project_root/build/native-drop-routing.XXXXXX")"
trap 'rm -f "$test_dir/tests"' EXIT
xcrun swift "$project_root/Tools/NativeDropRoutingTests/extract.swift" "$project_root" "$test_dir/Drop.swift"
sources=("$test_dir/Drop.swift" "$project_root/Tools/NativeDropRoutingTests/Boundary.swift"
         "$project_root/Tools/NativeDropRoutingTests/main.swift")
xcrun swiftc -swift-version 5 -target arm64-apple-macos12 -typecheck "${sources[@]}"
xcrun swiftc -swift-version 5 -sanitize=address -o "$test_dir/tests" "${sources[@]}"
ASAN_OPTIONS=detect_leaks=0 /usr/bin/perl -e 'alarm 20; exec @ARGV' "$test_dir/tests" 2>&1 | tee "$test_dir/results.log"
printf 'Artifacts: %s\n' "$test_dir"

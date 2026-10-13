#!/bin/bash

# Source after setting repo_root/test_dir. Never replace the repository's deps.
prepare_native_test_dependencies() {
  native_test_deps="${NATIVE_PLAYBACK_DEPS:-$repo_root/deps}"
  if [[ ! -d "$native_test_deps/include" || ! -d "$native_test_deps/lib" ]]; then
    printf 'Native test dependency directory is incomplete.\n' >&2
    return 2
  fi
  native_test_deps="$(cd "$native_test_deps" && pwd -P)"
  local name
  native_test_libraries=()
  for name in libavcodec.61.dylib libavformat.61.dylib libavutil.59.dylib libswresample.5.dylib libswscale.8.dylib; do
    if [[ ! -f "$native_test_deps/lib/$name" ]]; then
      printf 'Missing native test library: %s\n' "$name" >&2
      return 2
    fi
    native_test_libraries+=("$native_test_deps/lib/$name")
  done
  if [[ ! -f "$native_test_deps/include/libavcodec/avcodec.h" ]]; then
    printf 'Missing native test decoder header.\n' >&2
    return 2
  fi
  # Source-only hashes cannot distinguish old deps from an isolated candidate.
  /usr/bin/find -L "$native_test_deps/include" -type f -print0 | \
    /usr/bin/xargs -0 /usr/bin/shasum -a 256 > "$test_dir/dependency-sha256.txt"
  /usr/bin/shasum -a 256 "${native_test_libraries[@]}" >> "$test_dir/dependency-sha256.txt"
  printf '%s\n' "$native_test_deps" > "$test_dir/dependency-root.txt"
}

validate_native_test_dependencies() {
  /usr/bin/shasum -a 256 -c "$test_dir/dependency-sha256.txt" > "$test_dir/dependency-validation.log"
}

verify_native_test_runtime() {
  python3 -B "$repo_root/Tools/RenderTestSupport/verify_native_dependencies.py" \
    "$native_test_deps" > "$test_dir/dependency-runtime.json"
  # Record the remainder of the validated dynamic closure, not just direct links.
  local name
  for name in libavdevice.61.dylib libavfilter.10.dylib libpostproc.58.dylib libmpv.2.dylib; do
    /usr/bin/shasum -a 256 "$native_test_deps/lib/$name" >> "$test_dir/dependency-sha256.txt"
  done
}

#!/bin/bash
set -euo pipefail

# The isolated playback prefix contains static codec/font libraries. Always
# include their private link dependencies, while letting Meson resolve Apple's
# system-only iconv/zlib libraries as shared instead of demanding nonexistent .a files.
exec pkg-config --static "$@"

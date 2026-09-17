#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
: "${SPARKLE_TEST_ROOT:?Set SPARKLE_TEST_ROOT to the pinned Sparkle 2.10 artifact directory}"
# Never pass production release credentials into test processes.
unset SPARKLE_ED25519_PRIVATE_KEY
python3 -B "$script_dir/test_updates.py"

#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../.." && pwd)"
tests="$project_root/Tools/MediaInfoTests"

python3 "$tests/LocalizationTests.py"
bash "$tests/VideoReaderTests.run.sh"
bash "$tests/ImageRun.sh"
bash "$tests/LoaderRun.sh"
bash "$tests/RoutingRun.sh"
bash "$tests/WindowTests.sh"

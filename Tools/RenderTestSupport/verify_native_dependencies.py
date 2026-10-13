"""Reject native-test library identities that could resolve to another build."""
import importlib.util
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]


def main():
    if any(key.startswith("DYLD_") and value for key, value in os.environ.items()):
        raise RuntimeError("Native dependency verification requires an unmodified dyld environment")
    dependencies = Path(sys.argv[1]).resolve(strict=True)
    spec = importlib.util.spec_from_file_location("distribution", ROOT / "other/verify_playback_distribution.py")
    distribution = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(distribution)
    record = dependencies / "playback-build-record"
    # This checks the complete dynamic dependency closure, install names, rpaths,
    # ARM64 slices, hashes and signatures without imposing a newer source patch
    # requirement on an explicitly selected older regression build.
    distribution.validate_libraries(dependencies, record)
    distribution.validate_headers(dependencies, record)
    print(json.dumps({"dependencies": str(dependencies), "verified": True,
                      "library_sha256": distribution.checksum_records(record / "library-sha256.txt")}, indent=2))


if __name__ == "__main__":
    main()

"""Identify the sealed helper and player without collecting user information."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VERSION = r"[0-9]{1,5}(?:\.[0-9]{1,5}){1,3}"


def build_identity(source: Path = ROOT) -> dict[str, object]:
    config = (source.parents[1] / "Configs/Deployment.xcconfig").read_text()
    version = re.search(r"(?m)^MARKETING_VERSION\s*=\s*(\S+)\s*$", config)
    build = re.search(r"(?m)^CURRENT_PROJECT_VERSION\s*=\s*([0-9]+)\s*$", config)
    if not version or not re.fullmatch(VERSION, version[1]) or not build:
        raise ValueError("The player build identity is unavailable")
    digest = hashlib.sha256()
    files = [*source.glob("*.py"), *source.glob("*.spec"), *source.glob("*.sh")]
    files.extend(source / name for name in (
        "runtime-artifacts.json", "runtime-sources.json", "upstream-manifest.json",
    ))
    files.extend((source / "static").glob("*"))
    for path in sorted(files):
        if not path.is_file() or path.name == "diagnostic-build.json":
            continue
        digest.update(path.relative_to(source).as_posix().encode("utf-8") + b"\0")
        digest.update(path.read_bytes() + b"\0")
    return {
        "schema_version": 1,
        "player_version": version[1],
        "player_build": build[1],
        "helper_build_id": digest.hexdigest(),
    }


def _validate_identity(value: object) -> dict[str, str]:
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise ValueError("Invalid bundled build identity")
    result = {}
    for key, pattern in (
        ("player_version", VERSION),
        ("player_build", r"[0-9]{1,10}"),
        ("helper_build_id", r"[a-f0-9]{64}"),
    ):
        item = value.get(key)
        if not isinstance(item, str) or not re.fullmatch(pattern, item):
            raise ValueError("Invalid bundled build identity")
        result[key] = item
    return result


def runtime_identity() -> dict[str, str]:
    frozen = getattr(sys, "frozen", False)
    try:
        if frozen:
            # Only read our own sealed resource, never user configuration.
            path = ROOT / "diagnostic-build.json"
            with path.open("rb") as stream:
                data = stream.read(4097)
            if len(data) > 4096:
                raise ValueError("Oversized build identity")
            identity = _validate_identity(json.loads(data))
        else:
            identity = _validate_identity(build_identity())
        identity["identity_source"] = "bundled" if frozen else "development"
    except (OSError, ValueError, UnicodeError):
        identity = {"identity_source": "unavailable"}
    from app.build_info import APP_VERSION, BUILD_ID
    from yt_dlp.version import __version__ as downloader_version

    identity.update({
        "engine_version": APP_VERSION,
        "engine_build_id": BUILD_ID,
        "python_version": platform.python_version(),
        "macos_version": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "yt_dlp_version": downloader_version,
    })
    # The report's fixed schema validates these fields again before export.
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(build_identity(), sort_keys=True) + "\n")


if __name__ == "__main__":
    main()

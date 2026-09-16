"""Reject unpinned packages before PyInstaller discovers optional imports."""

from __future__ import annotations

import importlib.metadata
import json
import re
import site
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def normalized(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def expected_packages() -> dict[str, str]:
    expected = {
        normalized(item["name"]): item["version"]
        for item in json.loads((ROOT / "runtime-artifacts.json").read_text())[
            "artifacts"
        ]
    }
    build = (ROOT.parent / "VideoToolsHelper/requirements-build.txt").read_text()
    expected.update(
        {
            normalized(name): version
            for name, version in re.findall(r"(?m)^([\w-]+)==([^\s]+)", build)
        }
    )
    return expected


def validate_installed(installed: dict[str, str]) -> None:
    expected = expected_packages()
    unexpected = sorted(set(installed) - expected.keys() - {"pip"})
    mismatches = sorted(
        name for name, version in expected.items() if installed.get(name) != version
    )
    if unexpected or mismatches:
        raise RuntimeError(
            "Create a clean build venv and install only requirements-build.txt; "
            f"unexpected packages: {', '.join(unexpected) or 'none'}; "
            f"missing or mismatched packages: {', '.join(mismatches) or 'none'}"
        )


def main() -> None:
    if sys.prefix == sys.base_prefix or site.ENABLE_USER_SITE:
        raise RuntimeError(
            "A clean virtual environment without system-site-packages is required"
        )
    installed = {}
    for distribution in importlib.metadata.distributions():
        name = normalized(distribution.metadata["Name"])
        if name in installed:
            raise RuntimeError(f"Duplicate installed distribution: {name}")
        installed[name] = distribution.version
    validate_installed(installed)


if __name__ == "__main__":
    main()

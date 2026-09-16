"""Collect notices from the exact installed and checksum-pinned runtime wheels."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import re
import shutil
from pathlib import Path


def collect(destination: Path, source: Path) -> None:
    manifest = json.loads(
        (source / "runtime-artifacts.json").read_text(encoding="utf-8")
    )
    destination.mkdir(parents=True, exist_ok=True)
    for package in manifest["artifacts"]:
        distribution = importlib.metadata.distribution(package["name"])
        if distribution.version != package["version"]:
            raise RuntimeError(
                f"Installed runtime does not match lock: {package['name']}"
            )
        name = re.sub(r"[-_.]+", "-", package["name"]).lower()
        package_dir = destination / name
        package_dir.mkdir()
        copied = 0
        for entry in distribution.files or ():
            if not re.search(
                r"(?i)(^|/)(licen[cs]e[^/]*|notice[^/]*|copying[^/]*|[^/]+\.licen[cs]e(?:\.txt)?)$",
                str(entry),
            ):
                continue
            original = distribution.locate_file(entry)
            if not original.is_file():
                continue
            relative = Path(
                *[part for part in entry.parts if part not in ("..", ".", "/")]
            )
            target = package_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            copied += 1
        if not copied:
            raise RuntimeError(
                f"The runtime wheel contains no license notice: {package['name']}"
            )
    shutil.copyfile(
        source / "vendor/rednote/LICENSE",
        destination / "RednoteDownloader-MIT-LICENSE.txt",
    )
    shutil.copyfile(
        source / "runtime-artifacts.json", destination / "runtime-artifacts.json"
    )
    shutil.copyfile(source / "DISTRIBUTION.md", destination / "DISTRIBUTION.md")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    collect(arguments.destination, Path(__file__).resolve().parent)

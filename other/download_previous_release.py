"""Fetch the immutable previous stable update assets before building a delta."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

from verify_appcast import RELEASES, REPOSITORY, require, version_tuple


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def release_assets(release, current_tag):
    require(isinstance(release, dict), "Invalid previous release metadata.")
    tag = release.get("tag_name", "")
    require(
        isinstance(tag, str) and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag),
        "Previous release must have a stable numeric tag.",
    )
    require(
        re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", current_tag)
        and version_tuple(tag[1:]) < version_tuple(current_tag[1:]),
        "Delta base must be an older stable release.",
    )
    require(
        release.get("draft") is False
        and release.get("prerelease") is False
        and release.get("html_url") == f"{RELEASES}/tag/{tag}"
        and isinstance(release.get("published_at"), str)
        and bool(release["published_at"]),
        "Delta base must be a published stable release in this repository.",
    )
    assets = release.get("assets")
    require(isinstance(assets, list), "Missing previous release assets.")
    require(
        all(
            isinstance(asset, dict) and isinstance(asset.get("name"), str)
            for asset in assets
        ),
        "Invalid previous release asset metadata.",
    )
    names = [asset["name"] for asset in assets]
    require(len(names) == len(set(names)), "Duplicate previous release asset names.")
    archive = f"ChengYingPlayer-{tag}-Apple-Silicon.dmg"
    limits = {archive: 4 * 1024**3, archive + ".sha256": 1024, "appcast.xml": 1024**2}
    selected = {}
    for name, limit in limits.items():
        matches = [asset for asset in assets if asset["name"] == name]
        require(len(matches) == 1, "Missing required previous release asset.")
        asset = matches[0]
        require(
            asset.get("state") == "uploaded"
            and type(asset.get("size")) is int
            and 0 < asset["size"] <= limit
            and isinstance(asset.get("digest"), str)
            and re.fullmatch(r"sha256:[a-f0-9]{64}", asset["digest"])
            and asset.get("browser_download_url")
            == f"{RELEASES}/download/{tag}/{name}",
            "Previous release asset failed repository, size or digest policy.",
        )
        selected[name] = asset
    return tag, selected


def verify_downloads(directory, release, current_tag):
    tag, assets = release_assets(release, current_tag)
    for name, asset in assets.items():
        path = directory / name
        require(
            path.is_file() and not path.is_symlink(),
            "Previous asset must be a regular file.",
        )
        require(
            path.stat().st_size == asset["size"]
            and f"sha256:{digest(path)}" == asset["digest"],
            "Previous release asset does not match its published digest.",
        )
    archive = directory / f"ChengYingPlayer-{tag}-Apple-Silicon.dmg"
    checksum = archive.with_suffix(".dmg.sha256")
    require(
        checksum.read_bytes() == f"{digest(archive)}  {archive.name}\n".encode("ascii"),
        "Previous archive checksum does not match the immutable release.",
    )
    return tag, archive, directory / "appcast.xml"


def download(destination, current_tag):
    require(
        not destination.exists(), "Previous release output must be a new directory."
    )
    result = subprocess.run(
        ["gh", "api", "--method", "GET", f"repos/{REPOSITORY}/releases/latest"],
        check=True,
        capture_output=True,
        timeout=120,
    )
    require(
        len(result.stdout) <= 4 * 1024**2, "Previous release metadata is too large."
    )
    release = json.loads(result.stdout)
    tag, assets = release_assets(release, current_tag)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="previous-release-", dir=destination.parent
    ) as directory:
        staging = Path(directory) / "verified"
        staging.mkdir()
        for name, asset in assets.items():
            subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--proto",
                    "=https",
                    "--proto-redir",
                    "=https",
                    "--connect-timeout",
                    "30",
                    "--max-time",
                    "1200",
                    "--retry",
                    "3",
                    "--max-filesize",
                    str(asset["size"]),
                    "--output",
                    str(staging / name),
                    asset["browser_download_url"],
                ],
                check=True,
                timeout=1500,
            )
        verify_downloads(staging, release, current_tag)
        (staging / "release.json").write_text(json.dumps(release), encoding="utf-8")
        staging.rename(destination)
    print(
        f"Downloaded and digest-verified previous stable release {tag}; signature verification remains required."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    download(args.output_directory, args.tag)


if __name__ == "__main__":
    main()

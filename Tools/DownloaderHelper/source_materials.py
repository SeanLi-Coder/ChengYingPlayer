"""Fetch and package exact runtime sources without executing upstream code."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "runtime-sources.json"
RUST_MANIFEST = ROOT / "rust-sources.json"


def records(manifest: Path = MANIFEST) -> list[dict]:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("Unsupported runtime source manifest")
    names, filenames = set(), set()
    for item in data["artifacts"]:
        name, filename = item["name"], item["filename"]
        url = urlsplit(item["url"])
        if (
            name in names
            or filename in filenames
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]+", name)
            or Path(filename).name != filename
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]+", filename)
            or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])
            or url.scheme != "https"
            or not url.hostname
            or url.username
            or url.password
            or url.fragment
        ):
            raise ValueError("Invalid or duplicate runtime source record")
        names.add(name)
        filenames.add(filename)
    return data["artifacts"]


def all_records() -> list[dict]:
    return [*records(), *records(RUST_MANIFEST)]


def fetch_all(cache: Path) -> list[tuple[dict, Path]]:
    items = all_records()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        paths = list(executor.map(lambda item: fetch(item, cache), items))
    return list(zip(items, paths, strict=True))


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(item: dict, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / item["filename"]
    if destination.is_symlink():
        raise ValueError("Source cache entries must not be symlinks")
    if destination.is_file() and digest(destination) == item["sha256"]:
        return destination
    descriptor, temporary = tempfile.mkstemp(prefix=".source-", dir=cache)
    os.close(descriptor)
    partial = Path(temporary)
    try:
        subprocess.run(
            [
                "curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--connect-timeout",
                "30",
                "--max-time",
                "900",
                "--retry",
                "3",
                "--retry-all-errors",
                item["url"],
                "--output",
                str(partial),
            ],
            check=True,
        )
        if digest(partial) != item["sha256"]:
            raise ValueError(f"Runtime source checksum mismatch: {item['name']}")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def package(destination: Path, cache: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for item, original in fetch_all(cache):
        target = destination / item["filename"]
        if target.resolve() != original.resolve():
            shutil.copyfile(original, target)
    shutil.copyfile(MANIFEST, destination / "RUNTIME-SOURCE-MANIFEST.json")
    shutil.copyfile(RUST_MANIFEST, destination / "RUST-SOURCE-MANIFEST.json")


def collect_source_notices(destination: Path, cache: Path) -> None:
    """Retain upstream notices from archives; never extract executable sources."""
    destination.mkdir(parents=True, exist_ok=True)
    for item, original in fetch_all(cache):
        with tarfile.open(original) as archive:
            for entry in archive:
                relative = PurePosixPath(entry.name)
                if not entry.isfile() or not re.match(
                    r"(?i)^(licen[cs]e|copying|notice|copyright|authors|patents)([._-].*)?$",
                    relative.name,
                ):
                    continue
                if (
                    relative.is_absolute()
                    or ".." in relative.parts
                    or entry.size > 8 * 1024 * 1024
                ):
                    raise ValueError("Unsafe source notice archive member")
                target = destination / item["name"] / Path(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = archive.extractfile(entry)
                if stream is None:
                    raise ValueError("Unreadable source notice")
                with stream, target.open("wb") as output:
                    shutil.copyfileobj(stream, output)
    shutil.copyfile(MANIFEST, destination / "RUNTIME-SOURCE-MANIFEST.json")
    shutil.copyfile(RUST_MANIFEST, destination / "RUST-SOURCE-MANIFEST.json")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("fetch", "package", "notices", "manifest"))
    parser.add_argument("destination", type=Path, nargs="?")
    parser.add_argument(
        "--cache", type=Path, default=ROOT.parents[1] / "deps/sources/download-runtime"
    )
    args = parser.parse_args()
    if args.action == "manifest":
        for item in all_records():
            print(
                f"{item['sha256']}  {item['filename']}  {item['name']}  {item['version']}  {item['url']}"
            )
        return
    if args.destination is None:
        parser.error("A destination is required for this action")
    if args.action == "fetch":
        for _, path in fetch_all(args.destination):
            print(path, flush=True)
    elif args.action == "package":
        package(args.destination, args.cache)
    else:
        collect_source_notices(args.destination, args.cache)


if __name__ == "__main__":
    main()

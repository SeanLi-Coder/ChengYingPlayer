"""Verify the locked FFmpeg modifications and the matching media executables."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

from verify_playback_distribution import (
    PROJECT_ROOT,
    checksum_records,
    digest_file,
    parse_sources,
    read_text,
    require,
    validate_patches,
)

COMPONENTS = {
    "ffmpeg",
    "x264",
    "x265",
    "freetype",
    "harfbuzz",
    "fribidi",
    "libunibreak",
    "libass",
}


def source_locks():
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; third_party_source_records',
            "media-source-locks",
            str(PROJECT_ROOT / "other/third_party_sources.sh"),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return {
        name: record
        for name, record in parse_sources(result.stdout).items()
        if name in COMPONENTS
    }


def patch_locks():
    root = PROJECT_ROOT / "other/patches"
    patches = parse_sources(read_text(root / "media-patches.tsv"))
    for _name, _component, filename, _origin, expected in patches.values():
        require(
            digest_file(root / filename) == expected,
            f"Media patch checksum mismatch: {filename}",
        )
    return (
        patches,
        checksum_records(root / "media-before-sha256.txt"),
        checksum_records(root / "media-after-sha256.txt"),
    )


def validate(
    dependencies: Path, source_cache: Path, executable_directory: Path | None = None
):
    record = dependencies / "media-build-record"
    executable_directory = executable_directory or dependencies / "executable"
    sources = source_locks()
    require(set(sources) == COMPONENTS, "Media source locks are incomplete.")
    require(
        parse_sources(read_text(record / "sources.tsv")) == sources,
        "Recorded media sources differ from the current locks.",
    )
    for component, _version, filename, _origin, expected in sources.values():
        require(
            digest_file(source_cache / filename) == expected,
            f"Media source archive checksum mismatch: {component}",
        )
    validate_patches(record, source_cache, sources, patch_spec=patch_locks())
    hashes = checksum_records(record / "executable-sha256.txt")
    require(
        set(hashes) == {"ffmpeg", "ffprobe"}, "Media executable records are incomplete."
    )
    for name, expected in hashes.items():
        require(
            digest_file(executable_directory / name) == expected,
            f"Media executable checksum mismatch: {name}",
        )
    configuration = read_text(record / "config.h")
    for setting in ("CONFIG_LIBX265", "CONFIG_GPL", "CONFIG_VERSION3"):
        require(
            re.search(rf"^#define {setting} 1$", configuration, re.MULTILINE),
            f"Required media configuration is missing: {setting}",
        )
    make_configuration = read_text(record / "config.mak")
    require(
        "<BUILD_ROOT>" in make_configuration
        and "chengying-media-runtime." not in make_configuration
        and "chengying-media-runtime." not in configuration,
        "Media build configuration is not recorded with normalized paths.",
    )
    toolchain = read_text(record / "toolchain.txt")
    require(
        "Apple clang version " in toolchain and "SDK: " in toolchain,
        "Media build toolchain record is incomplete.",
    )
    result = subprocess.run(
        [
            str(executable_directory / "ffmpeg"),
            "-hide_banner",
            "-h",
            "encoder=libx265",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    require(
        re.search(r"^\s+-hdr10plus\s+<boolean>", result.stdout, re.MULTILINE),
        "FFmpeg does not support explicit HDR10+ preservation.",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dependencies", type=Path)
    parser.add_argument("--executable-directory", type=Path)
    parser.add_argument(
        "--source-cache", type=Path, default=PROJECT_ROOT / "deps/sources"
    )
    args = parser.parse_args()
    executable_directory = (
        args.executable_directory.resolve() if args.executable_directory else None
    )
    validate(
        args.dependencies.resolve(), args.source_cache.resolve(), executable_directory
    )
    print("Media source, patch and executable records verified.")


if __name__ == "__main__":
    main()

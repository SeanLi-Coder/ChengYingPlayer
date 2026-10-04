"""Verify the locked FFmpeg modifications and the matching media executables."""

from __future__ import annotations

import argparse
import os
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


def validate_record_paths(configuration: str, make_configuration: str) -> None:
    private_paths = ("/Users/", "/var/folders/", "/private/var/", "/tmp/")
    require(
        "<BUILD_ROOT>" in make_configuration,
        "Media config.mak is missing the normalized build root.",
    )
    for name, content in (
        ("config.h", configuration),
        ("config.mak", make_configuration),
    ):
        require(
            "chengying-media-runtime." not in content,
            f"Media {name} retains an unnormalized build workspace path.",
        )
        require(
            not any(path in content for path in private_paths),
            f"Media {name} retains a private host path.",
        )


def normalize_build_records(record: Path, build_root: str) -> None:
    """Replace only exact raw, lexical and physical aliases of this build root."""
    lexical_root = os.path.normpath(build_root)
    require(
        os.path.isabs(lexical_root)
        and Path(lexical_root).name.startswith("chengying-media-runtime."),
        "Expected an absolute media build workspace path.",
    )
    aliases = {build_root.rstrip("/"), lexical_root, os.path.realpath(build_root)}
    expression = re.compile(
        r"(^|[\s='\",:]|(?<![\w./-])-[IL])(?:"
        + "|".join(re.escape(value) for value in sorted(aliases, key=len, reverse=True))
        + r")(?=/|\s|['\"]|$)",
        re.MULTILINE,
    )
    normalized = {
        name: expression.sub(
            lambda match: match[1] + "<BUILD_ROOT>", read_text(record / name)
        )
        for name in ("config.h", "config.mak")
    }
    # Validate both complete records before writing either one. Unrelated private
    # paths are rejected rather than erased from the published build evidence.
    validate_record_paths(normalized["config.h"], normalized["config.mak"])
    for name, content in normalized.items():
        (record / name).write_text(content, encoding="utf-8")


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
    validate_record_paths(configuration, make_configuration)
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
    parser.add_argument("dependencies", type=Path, nargs="?")
    parser.add_argument("--executable-directory", type=Path)
    parser.add_argument("--normalize-record", type=Path)
    parser.add_argument("--build-root")
    parser.add_argument(
        "--source-cache", type=Path, default=PROJECT_ROOT / "deps/sources"
    )
    args = parser.parse_args()
    if args.normalize_record is not None:
        if (
            not args.build_root
            or args.dependencies is not None
            or args.executable_directory
        ):
            parser.error(
                "--normalize-record requires --build-root and no executable inputs"
            )
        normalize_build_records(args.normalize_record.resolve(), args.build_root)
        print("Media build configuration paths normalized and verified.")
        return
    if args.dependencies is None or args.build_root:
        parser.error("Specify dependencies, or --normalize-record with --build-root")
    executable_directory = (
        args.executable_directory.resolve() if args.executable_directory else None
    )
    validate(
        args.dependencies.resolve(), args.source_cache.resolve(), executable_directory
    )
    print("Media source, patch and executable records verified.")


if __name__ == "__main__":
    main()

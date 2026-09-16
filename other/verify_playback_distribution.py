"""Fail closed before distributing the source-built Apple Silicon playback stack."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PLAYBACK_COMPONENTS = {
    "playback-ffmpeg",
    "mpv",
    "libplacebo",
    "dav1d",
    "lcms2",
    "zimg",
    "fast-float",
    "uchardet",
}
SHARED_COMPONENTS = {"freetype", "harfbuzz", "fribidi", "libunibreak", "libass"}
SDK_DIRECTORIES = {
    "mpv",
    "libavcodec",
    "libavdevice",
    "libavfilter",
    "libavformat",
    "libavutil",
    "libpostproc",
    "libswresample",
    "libswscale",
}
SHA256 = re.compile(r"[0-9a-f]{64}")
LIBRARIES = {
    "libmpv.2.dylib",
    "libavcodec.61.dylib",
    "libavdevice.61.dylib",
    "libavfilter.10.dylib",
    "libavformat.61.dylib",
    "libavutil.59.dylib",
    "libpostproc.58.dylib",
    "libswresample.5.dylib",
    "libswscale.8.dylib",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_text(path):
    require(
        path.is_file() and not path.is_symlink(),
        f"Missing or linked build-record file: {path}",
    )
    require(
        0 < path.stat().st_size <= 25 * 1024 * 1024,
        f"Empty or oversized build-record file: {path}",
    )
    return path.read_text(encoding="utf-8")


def digest_file(path):
    require(
        path.is_file() and not path.is_symlink(),
        f"Missing or linked distribution file: {path}",
    )
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_sources(text):
    records = {}
    for line in text.splitlines():
        fields = line.split("\t")
        require(
            len(fields) == 5 and all(fields),
            "A source record must contain five nonempty tab-separated fields.",
        )
        component, version, filename, url, digest = fields
        require(component not in records, f"Duplicate source record: {component}")
        require(
            Path(filename).name == filename and filename not in {".", ".."},
            f"Invalid source filename: {filename}",
        )
        require(
            url.startswith("https://") and SHA256.fullmatch(digest),
            f"Invalid source URL or checksum: {component}",
        )
        records[component] = (component, version, filename, url, digest)
    return records


def locked_sources():
    # Only repository-owned lock scripts are sourced. Never execute build-record data.
    environment = os.environ.copy()
    for key in ("BASH_ENV", "ENV", "CDPATH"):
        environment.pop(key, None)

    def script_records(filename, function):
        result = subprocess.run(
            [
                "/bin/bash",
                "--noprofile",
                "--norc",
                "-c",
                'set -e; source "$1"; "$2"',
                "playback-source-locks",
                str(PROJECT_ROOT / "other" / filename),
                function,
            ],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        return parse_sources(result.stdout)

    playback = script_records("playback_sources.sh", "playback_source_records")
    all_records = script_records("third_party_sources.sh", "third_party_source_records")
    shared = {
        name: value for name, value in all_records.items() if name in SHARED_COMPONENTS
    }
    require(
        PLAYBACK_COMPONENTS.issubset(playback)
        and set(shared) == SHARED_COMPONENTS
        and not set(playback).intersection(shared),
        "Playback source locks are missing required components or contain conflicting component identities.",
    )
    return {**playback, **shared}


def checksum_records(path):
    records = {}
    for line in read_text(path).splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        require(match is not None, f"Invalid checksum record in {path.name}.")
        digest, name = match.groups()
        name = name.removeprefix("./")
        relative = PurePosixPath(name)
        require(
            not relative.is_absolute()
            and ".." not in relative.parts
            and str(relative) == name,
            f"Unsafe checksum path: {name}",
        )
        require(name not in records, f"Duplicate checksum path: {name}")
        records[name] = digest
    return records


def validate_configuration(record):
    toolchain = read_text(record / "toolchain.txt")
    require(
        re.search(r"^Architecture: arm64$", toolchain, re.MULTILINE),
        "Playback build is not recorded as ARM64.",
    )
    require(
        re.search(
            r"^Deployment target: [0-9]+(?:\.[0-9]+){1,2}$", toolchain, re.MULTILINE
        ),
        "Missing macOS deployment target record.",
    )
    require(
        re.search(r"^SDK: [0-9]+(?:\.[0-9]+){1,2}$", toolchain, re.MULTILINE),
        "Missing macOS SDK version record.",
    )
    require(
        "Apple clang version " in toolchain and "cmake version " in toolchain,
        "Incomplete compiler/toolchain record.",
    )
    config = read_text(record / "config.h")
    for name, enabled in {
        "CONFIG_GPL": 1,
        "CONFIG_VERSION3": 1,
        "CONFIG_NONFREE": 0,
        "CONFIG_LIBDAV1D": 1,
        "CONFIG_LIBASS": 1,
        "CONFIG_LIBZIMG": 1,
        "CONFIG_VIDEOTOOLBOX": 1,
        "CONFIG_SECURETRANSPORT": 1,
        "CONFIG_AUDIOTOOLBOX": 1,
    }.items():
        require(
            re.search(rf"^#define {name} {enabled}$", config, re.MULTILINE),
            f"Unexpected FFmpeg build option: {name}",
        )
    read_text(record / "config_components.h")
    ffmpeg = read_text(record / "ffmpeg-config.mak")
    for option in (
        "--disable-autodetect",
        "--enable-shared",
        "--disable-static",
        "--enable-libdav1d",
        "--enable-videotoolbox",
        "--enable-gpl",
        "--enable-version3",
    ):
        require(option in ffmpeg, f"Missing FFmpeg configuration flag: {option}")
    require(
        "--enable-nonfree" not in ffmpeg,
        "Nonfree FFmpeg cannot be distributed in this release.",
    )
    read_text(record / "mpv-config.h")

    def options(filename, expected):
        payload = json.loads(read_text(record / filename))
        require(
            isinstance(payload, list), f"Invalid Meson configuration record: {filename}"
        )
        values = {}
        for item in payload:
            require(
                isinstance(item, dict)
                and isinstance(item.get("name"), str)
                and "value" in item,
                f"Invalid Meson option entry: {filename}",
            )
            require(
                item["name"] not in values, f"Duplicate Meson option: {item['name']}"
            )
            values[item["name"]] = item["value"]
        for name, expected_value in expected.items():
            require(
                type(values.get(name)) is type(expected_value)
                and values[name] == expected_value,
                f"Unexpected Meson build option {filename}: {name}",
            )

    options(
        "mpv-buildoptions.json",
        {
            "auto_features": "disabled",
            "prefer_static": False,
            "libmpv": True,
            "cplayer": False,
            "gpl": True,
            "lua": "disabled",
            "cocoa": "enabled",
            "gl-cocoa": "enabled",
            "gl": "enabled",
            "plain-gl": "enabled",
            "swift-build": "enabled",
            "videotoolbox-gl": "enabled",
            "coreaudio": "enabled",
            "lcms2": "enabled",
            "zimg": "enabled",
            "uchardet": "enabled",
            "libavdevice": "enabled",
        },
    )
    options(
        "libplacebo-buildoptions.json",
        {
            "auto_features": "disabled",
            "default_library": "static",
            "demos": False,
            "tests": False,
            "lcms": "enabled",
            "dovi": "enabled",
        },
    )


def validate_headers(dependencies, record):
    hashes = checksum_records(record / "headers-sha256.txt")
    require(
        {PurePosixPath(name).parts[0] for name in hashes} == SDK_DIRECTORIES,
        "Header SDK record does not contain exactly the nine published API directories.",
    )
    actual = set()
    for directory in SDK_DIRECTORIES:
        root = dependencies / "include" / directory
        require(
            root.is_dir() and not root.is_symlink(),
            f"Missing SDK directory: {directory}",
        )
        for path in root.rglob("*"):
            require(not path.is_symlink(), f"Linked SDK file or directory: {path}")
            if path.is_file():
                actual.add(str(path.relative_to(dependencies / "include")))
    require(
        actual == set(hashes),
        "Header SDK files differ from the source-build checksum record.",
    )
    for name, expected in hashes.items():
        require(
            digest_file(dependencies / "include" / name) == expected,
            f"Header SDK checksum mismatch: {name}",
        )


def native_command(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def validate_libraries(dependencies, record, runner=native_command):
    hashes = checksum_records(record / "library-sha256.txt")
    require(
        set(hashes) == LIBRARIES,
        "Playback library checksum record must contain exactly the nine published dylibs.",
    )
    for name in sorted(LIBRARIES):
        library = dependencies / "lib" / name
        require(
            digest_file(library) == hashes[name],
            f"Playback library checksum mismatch: {name}",
        )
        require(
            runner(["lipo", "-archs", str(library)]).strip() == "arm64",
            f"Playback dylib is not a source-built ARM64-only binary: {name}",
        )
        lines = runner(["otool", "-L", str(library)]).splitlines()
        require(len(lines) >= 2, f"Missing playback install name: {name}")
        links = []
        for line in lines[1:]:
            match = re.fullmatch(r"\s+(.+?) \(compatibility version .+\)", line)
            require(match is not None, f"Unrecognized dependency record: {name}")
            links.append(match.group(1))
        require(
            links[0] == "@rpath/" + name, f"Unexpected playback install name: {name}"
        )
        for link in links[1:]:
            normalized = os.path.normpath(link)
            internal = (
                link.startswith("@rpath/") and link[len("@rpath/") :] in LIBRARIES
            )
            require(
                internal or normalized.startswith(("/usr/lib/", "/System/Library/")),
                f"External or untracked playback dependency: {name}: {link}",
            )
        commands = runner(["otool", "-l", str(library)]).splitlines()
        is_rpath = False
        for line in commands:
            tokens = line.split()
            if len(tokens) == 2 and tokens[0] == "cmd":
                is_rpath = tokens[1] == "LC_RPATH"
            elif is_rpath and len(tokens) >= 2 and tokens[0] == "path":
                value = tokens[1]
                require(
                    value == "/usr/lib/swift" or value == "@loader_path",
                    f"Unexpected playback runtime search path: {name}: {value}",
                )
        runner(["codesign", "--verify", "--strict", str(library)])


def is_notice(filename):
    return any(
        fnmatch.fnmatchcase(filename.lower(), pattern)
        for pattern in (
            "copying*",
            "license*",
            "licence*",
            "copyright*",
            "notice*",
            "authors*",
            "ftl.txt",
        )
    )


def validate_licenses(record, source_cache, sources):
    expected = {}
    component_roots = set()
    for component, _version, filename, _url, digest in sources.values():
        archive = source_cache / filename
        require(
            digest_file(archive) == digest,
            f"Playback source archive checksum mismatch: {component}",
        )
        component_notices = {}
        with tarfile.open(archive, mode="r:*") as contents:
            for member in contents:
                name = member.name.removeprefix("./")
                relative = PurePosixPath(name)
                require(
                    not relative.is_absolute() and ".." not in relative.parts,
                    f"Unsafe source archive path: {component}",
                )
                if not (member.isfile() or member.islnk()) or not is_notice(
                    relative.name
                ):
                    continue
                require(
                    len(relative.parts) >= 2 and 0 <= member.size <= 25 * 1024 * 1024,
                    f"Invalid source license entry: {name}",
                )
                require(
                    name not in component_notices,
                    f"Duplicate source license entry: {name}",
                )
                stream = contents.extractfile(member)
                require(stream is not None, f"Unreadable source license: {name}")
                with stream:
                    data = stream.read(25 * 1024 * 1024 + 1)
                require(
                    len(data) <= 25 * 1024 * 1024, f"Oversized source license: {name}"
                )
                component_notices[name] = hashlib.sha256(data).hexdigest()
        require(
            component_notices, f"No source license notices were found for {component}."
        )
        roots = {PurePosixPath(name).parts[0] for name in component_notices}
        require(
            len(roots) == 1 and not component_roots.intersection(roots),
            f"Ambiguous source license roots: {component}",
        )
        component_roots.update(roots)
        expected.update(component_notices)

    root = record / "licenses"
    require(
        root.is_dir() and not root.is_symlink(),
        "Missing original playback license directory.",
    )
    actual = {}
    for path in root.rglob("*"):
        require(not path.is_symlink(), f"Linked playback license entry: {path}")
        if path.is_file():
            actual[str(path.relative_to(root))] = digest_file(path)
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    changed = sorted(
        name
        for name in set(actual).intersection(expected)
        if actual[name] != expected[name]
    )
    require(
        actual == expected,
        "Playback licenses differ from the original notices in the locked source archives. "
        f"Missing: {missing[:8]}; extra: {extra[:8]}; changed: {changed[:8]}.",
    )


def verify_distribution(
    dependencies, *, sources=None, source_cache=None, runner=native_command
):
    dependencies = dependencies.resolve(strict=True)
    record = dependencies / "playback-build-record"
    require(
        record.is_dir() and not record.is_symlink(),
        "Missing source-built playback distribution record.",
    )
    expected = locked_sources() if sources is None else sources
    recorded = parse_sources(read_text(record / "sources.tsv"))
    require(
        recorded == expected,
        "Playback source build records differ from the complete set of current locked sources.",
    )
    cache = source_cache or Path(
        os.environ.get("SOURCE_CACHE_DIR", str(dependencies / "sources"))
    )
    validate_configuration(record)
    validate_headers(dependencies, record)
    validate_libraries(dependencies, record, runner)
    validate_licenses(record, cache.resolve(strict=True), expected)
    print(
        f"Verified source-built playback distribution: {len(expected)} locked sources, 9 ARM64 dylibs, SDK, build options, and original licenses."
    )


def main():
    require(
        len(sys.argv) == 2, "Usage: verify_playback_distribution.py <deps-directory>"
    )
    verify_distribution(Path(sys.argv[1]))


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        OSError,
        tarfile.TarError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Playback distribution verification failed: {error}", file=sys.stderr)
        sys.exit(1)

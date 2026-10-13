#!/usr/bin/env python3
"""Package one verified, non-sanitized AV1 CLI without relinking or resigning it."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BINARY_SHA = "6e3b855cf3f052368685efd4bbbcc8c28c17b02c583d23afacd9850046068c11"
LIBRARIES = {
    "libavcodec.61.dylib": "a183c8200217cf86a17817d6049efeb3502102bb02756224994d5ed5dec62dcc",
    "libavformat.61.dylib": "cb1ab278f8b1b001037e53d454a03a72fc72e8c3db89bc370be1f93b12d89a26",
    "libavutil.59.dylib": "6e58b12ee7cafd61a197558a295ced2cbad516faebb766edfd7dbd312445ff37",
    "libswresample.5.dylib": "2037ca49a7c02651c0ae37e2a11777613c386f963d7304d713477a95c75abeb7",
    "libswscale.8.dylib": "698221453b2bda84c1f3150a5778e1920654e752596ff11981c3081b12c6563c",
}
FIXTURES = {
    "av1-8.mkv": "f1f6902c69e843bc33da03bf2b098ddd76265d3a0fbee10e85dbc668d022c5cd",
    "av1-10.mkv": "538bc8f71c1ad1d60f73da0f773998c17ccc35b5727e1934386304d3aa2c3842",
    "reference-8.yuv": "21ab2f0671a5f953b9091a657a9c452a516e9d472270c088a283698486b95f98",
    "reference-10.yuv": "e2d794eb9c29fe4c1fa3473fa366ad14598590bdcbd4beafda7c4d681f04d8d1",
    "reference.f32": "3b58433bd1d397bd303302ad60df76ad3e7f30f84df64e016db42e86632a0f2a",
}
SOURCE_SHA = {
    "iina/NativePlayback/CYNMediaDecoder.m": "e3bcc18ecde84e48cf5556308eac7fc9802d6e5818ceecabe5b85e738b8958b9",
    "iina/NativePlayback/CYNMediaDecoder.h": "e4bc3e313c2635287ed3f44847e2fd37b4a7bea8af6c0baea21dfa01be790551",
    "Tools/NativeAV1Tests/main.m": "380fc15a2a898fbdd6b825f529a9cfc375a86a43abed6d7c583a1eb7380cca89",
}
SHELL_LAUNCHER = '''#!/bin/sh
set -eu
case "$0" in */*) bundle_dir=${0%/*} ;; *) bundle_dir=. ;; esac
cd -P -- "$bundle_dir"
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C /usr/bin/perl ./verify-and-run.pl "$@"
'''


def sha(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected a regular, non-symlink file: " + path.name)
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify(path: Path, expected: str) -> None:
    if sha(path) != expected:
        raise ValueError("Changed input: " + path.name)


def verify_record(path: Path) -> None:
    lines = path.read_text().splitlines()
    if not lines:
        raise ValueError("Empty evidence manifest")
    seen = set()
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in seen:
            raise ValueError("Malformed evidence manifest")
        seen.add(match[2])
        verify(Path(match[2]), match[1])


def macho(path: Path) -> dict:
    """Read load commands without Xcode tools; reject fat, truncated or alien files."""
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError("Truncated Mach-O")
    magic, cpu, _, kind, ncmds, size, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x100000C or kind not in (2, 6):
        raise ValueError("Expected a thin arm64 executable or dylib")
    if size > len(data) - 32:
        raise ValueError("Truncated load commands")
    offset = 32
    result = {"kind": kind, "dependencies": [], "rpaths": [], "minimum": None}
    for _ in range(ncmds):
        if offset + 8 > 32 + size:
            raise ValueError("Truncated load command")
        cmd, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError("Invalid load command length")
        if cmd == 0x32:
            if length < 24:
                raise ValueError("Truncated build version")
            platform, version = struct.unpack_from("<2I", data, offset + 8)
            if platform != 1 or result["minimum"] is not None:
                raise ValueError("Unexpected platform/version declaration")
            result["minimum"] = (version >> 16, (version >> 8) & 255, version & 255)
        if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023, 0x8000001C):
            if length < 12:
                raise ValueError("Truncated dependency")
            string_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if string_offset < 12 or string_offset >= length:
                raise ValueError("Invalid dependency string")
            value = data[offset + string_offset:offset + length].split(b"\0", 1)[0].decode()
            result["rpaths" if cmd == 0x8000001C else "dependencies"].append(value)
        offset += length
    if offset != size + 32:
        raise ValueError("Inconsistent load command count")
    return result


def validate_closure(binary: Path, libs: Path) -> dict:
    """Every non-system dependency must be one of the five pinned libraries."""
    pending = [binary]
    visited = set()
    metadata = macho(binary)
    if metadata["kind"] != 2 or metadata["minimum"] != (26, 0, 0):
        raise ValueError("This acceptance executable requires macOS 26.0 exactly")
    while pending:
        path = pending.pop()
        if path.name in visited:
            continue
        visited.add(path.name)
        for dep in macho(path)["dependencies"]:
            if dep.startswith(("/System/Library/", "/usr/lib/")):
                continue
            name = dep.removeprefix("@rpath/")
            if dep != "@rpath/" + name or name not in LIBRARIES:
                raise ValueError("Non-portable or unexpected dependency")
            pending.append(libs / name)
    if visited != {binary.name, *LIBRARIES}:
        raise ValueError("Dependency closure does not match the pinned set")
    return metadata


def render_launcher(policy: dict) -> str:
    template = (HERE / "launch.pl.in").read_text()
    if template.count("@@POLICY@@") != 1:
        raise ValueError("Expected exactly one policy placeholder")
    return template.replace("@@POLICY@@", json.dumps(policy, sort_keys=True))


def build(evidence: Path, deps: Path, source_cache: Path) -> Path:
    # Frozen build identity: changing the candidate requires a reviewed new record.
    binary = evidence / "native-av1-tests"
    verify(binary, BINARY_SHA)
    for name, digest in SOURCE_SHA.items():
        verify(ROOT / name, digest)
    provenance = json.loads((evidence / "provenance.json").read_text())
    if any(provenance.get(key) is not None for key in ("sanitizer", "negative_control")):
        raise ValueError("Sanitizer or negative-control executable is not portable evidence")
    if provenance.get("require_hardware") is not False or Path(provenance["deps"]).resolve() != deps.resolve():
        raise ValueError("Unexpected normal-run provenance")
    if json.loads((evidence / "hash-validation.json").read_text()) != {"changed": []}:
        raise ValueError("Original evidence integrity check did not pass")
    normal = (evidence / "results.log").read_text()
    if re.findall(r"^Native AV1 checks=\d+ failures=\d+ strict_hardware=\d+$", normal, re.M) != [
        "Native AV1 checks=7486 failures=0 strict_hardware=0"
    ] or re.search(r"^FAIL:", normal, re.M):
        raise ValueError("Original normal run did not pass completely")
    verify_record(evidence / "source.sha256")
    verify_record(evidence / "generated.sha256")
    inputs = {"bin/native-av1-tests": (binary, BINARY_SHA)}
    inputs.update({"lib/" + name: (deps / "lib" / name, digest) for name, digest in LIBRARIES.items()})
    inputs.update({"fixtures/" + name: (evidence / name, digest) for name, digest in FIXTURES.items()})
    for relative, (path, digest) in inputs.items():
        verify(path, digest)
        if relative.startswith("lib/") and provenance["library_sha256"].get(path.name) != digest:
            raise ValueError("Library identity disagrees with the verified build")
    validate_closure(binary, deps / "lib")
    (ROOT / "build").mkdir(exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix="m4-av1-acceptance.", suffix=".noindex", dir=ROOT / "build"))
    bundle = destination / "M4-AV1-Acceptance"
    bundle.mkdir()
    policy = {
        "schema": 1,
        "minimum_macos": 26,
        "architecture": "arm64",
        "timeout_seconds": 120,
        "diagnostic_timeout_seconds": 2,
        "expected_checks": 1738,
        "files": {relative: digest for relative, (_, digest) in inputs.items()},
        "libraries": sorted(LIBRARIES),
    }
    for relative, (path, digest) in inputs.items():
        target = bundle / relative
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(path, target)
        target.chmod(0o755 if relative.startswith(("bin/", "lib/")) else 0o644)
        verify(path, digest)
        verify(target, digest)
    source_spec = importlib.util.spec_from_file_location('av1_portable_sources', HERE / 'source_materials.py')
    source_module = importlib.util.module_from_spec(source_spec)
    source_spec.loader.exec_module(source_module)
    policy['files'].update(source_module.create(ROOT, deps, source_cache, bundle, sha, verify))
    launcher = bundle / "Run-M4-AV1-Check.command"
    launcher.write_text(SHELL_LAUNCHER)
    launcher.chmod(0o755)
    guide = bundle / "README.txt"
    shutil.copyfile(HERE / "PACKAGE_README.txt", guide)
    policy["files"][launcher.name] = sha(launcher)
    policy["files"][guide.name] = sha(guide)
    verifier = bundle / "verify-and-run.pl"
    verifier.write_text(render_launcher(policy))
    manifest = {
        "schema": 1,
        "architecture": "arm64",
        "minimum_macos": "26.0",
        "mode": "strict-hardware-only",
        "source_sha256": SOURCE_SHA,
        "files": {**policy["files"], verifier.name: sha(verifier)},
        "scope": "Synthetic 8/10-bit AV1 decode, seek, restart and reopen; not full App or 4K endurance",
        "signature": "Original linker ad-hoc signature retained; no Developer ID or notarization claim",
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    # Revalidate after all copies; do not turn a changing source into a valid package.
    for path, digest in inputs.values():
        verify(path, digest)
    verify_record(evidence / "source.sha256")
    verify_record(evidence / "generated.sha256")
    archive = Path(shutil.make_archive(str(destination / "M4-AV1-Acceptance"), "zip", destination, bundle.name))
    (destination / "M4-AV1-Acceptance.zip.sha256").write_text(sha(archive) + "  " + archive.name + "\n")
    print("Portable acceptance package: " + str(bundle))
    print("Transfer archive: " + str(archive))
    print("No decoder was run. No M4 hardware acceptance result is claimed.")
    return bundle


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=ROOT / "build/native-av1-tests.lnilr6qr")
    parser.add_argument("--deps", type=Path, default=ROOT / "build/native-av1-playback.7FMHum")
    parser.add_argument("--source-cache", type=Path, default=ROOT / "deps/sources",
                        help="Existing locked archives only; missing inputs fail without downloading")
    args = parser.parse_args()
    build(args.evidence.resolve(), args.deps.resolve(), args.source_cache.resolve())


if __name__ == "__main__":
    main()

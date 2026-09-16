"""Verify a real nested helper bundle and the containing application's signature."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from smoke_helper import run_smoke

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


def is_macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGICS


def validate_layout(application):
    contents = application / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    assert info["CFBundleExecutable"] == "chengying-download-center-helper"
    assert info["LSBackgroundOnly"] is True
    assert info["LSUIElement"] is True
    assert info["LSMinimumSystemVersion"] == "13.5"
    for relative in (
        "MacOS/chengying-download-center-helper",
        "MacOS/deno",
        "Frameworks/playwright/driver/node",
    ):
        executable = contents / relative
        assert executable.is_file() and is_macho(executable)
    for relative in (
        "Resources/vendor/rednote/app/main.py",
        "Resources/static/desktop.js",
        "Resources/Legal/runtime-artifacts.json",
        "Resources/truststore/_api.py",
    ):
        resource = contents / relative
        assert resource.is_file() and not resource.is_symlink()
    root = application.resolve()
    for path in application.rglob("*"):
        assert path.name != "__pycache__", path
        if path.is_symlink():
            assert not os.path.isabs(os.readlink(path)), path
            assert path.resolve(strict=True).is_relative_to(root), path
            continue
        if path.is_file() and path.is_relative_to(contents / "Resources"):
            assert not is_macho(path), path
    attributes = subprocess.run(
        ["xattr", "-r", str(application)],
        capture_output=True,
        text=True,
        check=True,
    )
    assert "com.apple.cs." not in attributes.stdout, (
        "A signature was stored in extended attributes"
    )
    assert (contents / "Frameworks/vendor/rednote").resolve() == (
        contents / "Resources/vendor/rednote"
    ).resolve()


def snapshot(directory):
    result = {}
    for path in directory.rglob("*"):
        relative = str(path.relative_to(directory))
        if path.is_symlink():
            result[relative] = ("link", os.readlink(path))
        elif path.is_file():
            with path.open("rb") as stream:
                result[relative] = (
                    "file",
                    hashlib.file_digest(stream, "sha256").hexdigest(),
                )
    return result


def run(application, ffmpeg, ffprobe):
    validate_layout(application)
    with tempfile.TemporaryDirectory(prefix="chengying nested signing ") as temporary:
        root = Path(temporary).resolve()
        host = root / "Test Player.app"
        contents = host / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers").mkdir()
        shutil.copyfile("/usr/bin/true", contents / "MacOS/host")
        (contents / "MacOS/host").chmod(0o755)
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "io.github.SeanLi-Coder.ChengYingPlayer.SigningTest",
                    "CFBundleExecutable": "host",
                    "CFBundlePackageType": "APPL",
                }
            )
        )
        embedded = contents / "Helpers/DownloadCenter.app"
        shutil.copytree(application, embedded, symlinks=True)
        # The host must seal a correctly signed child without recursively signing anything.
        subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                str(host),
            ],
            check=True,
        )
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(host)], check=True
        )
        before = snapshot(host)
        helper = embedded / "Contents/MacOS/chengying-download-center-helper"
        run_smoke([str(helper)], ffmpeg, ffprobe)
        forbidden = embedded / "Contents/Resources/user-data"
        rejected = subprocess.run(
            [
                str(helper),
                "--stdio",
                "--data-dir",
                str(forbidden),
                "--download-dir",
                str(root / "downloads"),
                "--ffmpeg",
                str(ffmpeg),
                "--ffprobe",
                str(ffprobe),
            ],
            input="",
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
        assert rejected.returncode != 0
        assert json.loads(rejected.stdout)["type"] == "failed"
        assert not forbidden.exists()
        assert snapshot(host) == before, (
            "Running the helper changed its signed host bundle"
        )
        validate_layout(embedded)
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(host)], check=True
        )
        # Confirm that resources are sealed, not excluded to get a superficial signature pass.
        resource = embedded / "Contents/Resources/static/desktop.js"
        with resource.open("ab") as stream:
            stream.write(b"\n// Signature tamper probe.\n")
        tampered = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(host)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert tampered.returncode != 0, "A modified nested resource was not detected"
    print(
        "Nested application layout, non-recursive host signing, stdio, resource sealing, and tamper checks passed."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    arguments = parser.parse_args()
    run(
        arguments.app.resolve(), arguments.ffmpeg.resolve(), arguments.ffprobe.resolve()
    )


if __name__ == "__main__":
    main()

"""Sign a verified release using pinned Sparkle tools and verify with its public key."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from verify_appcast import RELEASES, require, validate_info, verify

SPARKLE_VERSION = "2.10.0"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_sparkle(root):
    framework = root / "Sparkle.framework"
    if not framework.exists():
        framework = root / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    plist = framework / "Versions/B/Resources/Info.plist"
    with plist.open("rb") as stream:
        info = plistlib.load(stream)
    require(
        info.get("CFBundleShortVersionString") == SPARKLE_VERSION,
        "Signing requires the pinned Sparkle version.",
    )
    tool = root / "bin/generate_appcast"
    require(
        tool.is_file() and os.access(tool, os.X_OK),
        "Missing pinned Sparkle signing tool.",
    )
    return tool


def generate(app, archive, destination, tag, sparkle_root):
    # Remove the secret from child environments. Only the signing tool gets stdin.
    secret = os.environ.pop("SPARKLE_ED25519_PRIVATE_KEY", "")
    require(bool(secret.strip()), "The release signing secret is not configured.")
    require(
        destination.name == "appcast.xml" and not destination.exists(),
        "Feed output must be a new appcast.xml.",
    )
    require(
        archive.is_file() and not archive.is_symlink(),
        "Archive must be a regular file.",
    )
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    validate_info(info, tag)
    require(
        archive.name == f"ChengYingPlayer-{tag}-Apple-Silicon.dmg",
        "Unexpected release archive.",
    )
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = subprocess.check_output(
        ["lipo", "-archs", str(executable)], text=True
    ).split()
    require(architectures == ["arm64"], "Release application must be ARM64-only.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    tool = validate_sparkle(sparkle_root)
    before = digest(archive)
    with tempfile.TemporaryDirectory(prefix="chengying-feed-sign-") as directory:
        staging = Path(directory)
        staged_archive = staging / archive.name
        # A separate workspace prevents Sparkle from discovering other archives or deltas.
        shutil.copyfile(archive, staged_archive)
        result = subprocess.run(
            [
                str(tool),
                "--ed-key-file",
                "-",
                "--maximum-deltas",
                "0",
                "--download-url-prefix",
                f"{RELEASES}/download/{tag}/",
                "--link",
                RELEASES,
                str(staging),
            ],
            input=secret.encode(),
            capture_output=True,
            check=False,
            timeout=600,
        )
        secret = ""
        # Never echo signing-tool diagnostics: malformed credential input must stay private.
        require(
            result.returncode == 0,
            "Sparkle could not sign the release; check the signing configuration.",
        )
        require(
            digest(staged_archive) == before and digest(archive) == before,
            "Archive changed during signing.",
        )
        generated = staging / "appcast.xml"
        verify(generated, archive, info, tag)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("xb") as output:
            output.write(generated.read_bytes())
    print(
        "Signed appcast created and independently verified without exposing credentials."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sparkle-root", required=True, type=Path)
    args = parser.parse_args()
    generate(args.app, args.archive, args.output, args.tag, args.sparkle_root)


if __name__ == "__main__":
    main()

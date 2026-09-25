"""Build and round-trip a Sparkle delta from an authenticated stable application."""

from __future__ import annotations

import json
import os
import plistlib
import stat
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

from download_previous_release import digest, verify_downloads
from verify_appcast import (
    SPARKLE,
    require,
    validate_info,
    verify,
    verify_feed_signature,
    version_tuple,
)


def tree_manifest(root):
    """Compare bytes, modes and symlinks; Sparkle intentionally ignores dates/xattrs."""
    require(
        root.is_dir() and not root.is_symlink(),
        "Application tree must be a real directory.",
    )
    result = {}
    paths = [root]
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        paths.extend(Path(directory) / name for name in subdirectories + files)
    for path in paths:
        details = path.lstat()
        mode = stat.S_IMODE(details.st_mode)
        if stat.S_ISLNK(details.st_mode):
            value = ("symlink", os.readlink(path))
        elif stat.S_ISDIR(details.st_mode):
            value = ("directory", mode)
        elif stat.S_ISREG(details.st_mode):
            value = ("file", mode, details.st_size, digest(path))
        else:
            raise ValueError("Application tree contains an unsupported special file.")
        result[str(path.relative_to(root))] = value
    return result


def verify_application(app, info):
    require(
        app.is_dir() and not app.is_symlink(),
        "Release application must be a real directory.",
    )
    executable_name = info.get("CFBundleExecutable")
    require(executable_name == "ChengYing", "Unexpected application executable.")
    architectures = subprocess.check_output(
        ["lipo", "-archs", str(app / "Contents/MacOS" / executable_name)], text=True
    ).split()
    require(architectures == ["arm64"], "Delta application must be ARM64-only.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def verify_archive_application(archive, app, info, staging):
    """Ensure full and delta updates install the identical signed application."""
    mount = staging / "current-volume"
    mount.mkdir()
    mounted = False
    try:
        subprocess.run(
            [
                "hdiutil",
                "attach",
                "-quiet",
                "-readonly",
                "-nobrowse",
                "-noautoopen",
                "-mountpoint",
                str(mount),
                str(archive),
            ],
            check=True,
            timeout=120,
        )
        mounted = True
        candidates = list(mount.glob("*.app"))
        require(
            len(candidates) == 1 and candidates[0].name == "ChengYing.app",
            "Current archive must contain exactly the expected application.",
        )
        verify_application(candidates[0], info)
        require(
            tree_manifest(candidates[0]) == tree_manifest(app),
            "Full archive and delta target application differ.",
        )
    finally:
        if mounted:
            subprocess.run(
                ["hdiutil", "detach", "-quiet", str(mount)], check=True, timeout=120
            )


def authenticated_previous_app(directory, current_info, current_tag, staging):
    metadata = directory / "release.json"
    require(
        metadata.is_file() and not metadata.is_symlink(),
        "Missing previous release metadata.",
    )
    require(
        metadata.stat().st_size <= 4 * 1024**2,
        "Previous release metadata is too large.",
    )
    release = json.loads(metadata.read_bytes())
    old_tag, archive, feed = verify_downloads(directory, release, current_tag)
    # Authenticate the archive before mounting it. The key comes from the new,
    # trusted build, never from a downloaded application's unverified plist.
    content = verify_feed_signature(feed.read_bytes(), current_info["SUPublicEDKey"])
    item = ET.fromstring(content).find("channel/item")
    require(item is not None, "Missing previous signed update item.")
    expected_info = dict(
        current_info,
        CFBundleShortVersionString=old_tag[1:],
        CFBundleVersion=item.findtext(SPARKLE + "version"),
    )
    validate_info(expected_info, old_tag)
    require(
        int(expected_info["CFBundleVersion"]) < int(current_info["CFBundleVersion"]),
        "Delta base build must be older than the new application.",
    )
    verify(feed, archive, expected_info, old_tag, verify_deltas=False)
    mount = staging / "previous-volume"
    mount.mkdir()
    mounted = False
    try:
        subprocess.run(
            [
                "hdiutil",
                "attach",
                "-quiet",
                "-readonly",
                "-nobrowse",
                "-noautoopen",
                "-mountpoint",
                str(mount),
                str(archive),
            ],
            check=True,
            timeout=120,
        )
        mounted = True
        candidates = list(mount.glob("*.app"))
        require(
            len(candidates) == 1 and candidates[0].name == "ChengYing.app",
            "Previous archive must contain exactly the expected application.",
        )
        old_app = candidates[0]
        info_path = old_app / "Contents/Info.plist"
        require(
            info_path.is_file() and not info_path.is_symlink(),
            "Invalid previous application plist.",
        )
        info = plistlib.loads(info_path.read_bytes())
        require(
            validate_info(info, old_tag) == current_info["SUPublicEDKey"],
            "Previous application changed the trusted signing identity.",
        )
        require(
            info["CFBundleVersion"] == expected_info["CFBundleVersion"],
            "Previous archive and signed feed builds differ.",
        )
        verify_application(old_app, info)
        destination = staging / "previous/ChengYing.app"
        destination.parent.mkdir()
        subprocess.run(["ditto", str(old_app), str(destination)], check=True)
        require(
            tree_manifest(destination) == tree_manifest(old_app),
            "Previous application changed while copying from its verified archive.",
        )
    finally:
        if mounted:
            subprocess.run(
                ["hdiutil", "detach", "-quiet", str(mount)], check=True, timeout=120
            )
    return destination, info


def build_delta(app, archive, tag, info, previous_directory, sparkle_root, staging):
    old_app, old_info = authenticated_previous_app(
        previous_directory, info, tag, staging
    )
    old_framework = old_app / "Contents/Frameworks/Sparkle.framework/Versions/B"
    sparkle_info = old_framework / "Resources/Info.plist"
    require(
        sparkle_info.is_file(),
        "Previous application lacks its embedded Sparkle version.",
    )
    old_sparkle = plistlib.loads(sparkle_info.read_bytes())
    require(
        version_tuple(old_sparkle.get("CFBundleShortVersionString")) >= (2, 7, 0),
        "Previous Sparkle cannot apply the required delta format.",
    )
    tool = sparkle_root / "bin/BinaryDelta"
    require(
        tool.is_file() and os.access(tool, os.X_OK),
        "Missing pinned Sparkle delta tool.",
    )
    destination = (
        staging
        / f"ChengYingPlayer-{tag}-from-{old_info['CFBundleVersion']}-Apple-Silicon.delta"
    )
    original_tree = tree_manifest(app)
    subprocess.run(
        [
            str(tool),
            "create",
            "--version",
            "4",
            "--compression",
            "lzma",
            str(old_app),
            str(app),
            str(destination),
        ],
        check=True,
        timeout=1800,
    )
    reconstructed = staging / "reconstructed/ChengYing.app"
    reconstructed.parent.mkdir()
    subprocess.run(
        [str(tool), "apply", str(old_app), str(reconstructed), str(destination)],
        check=True,
        timeout=900,
    )
    require(
        tree_manifest(reconstructed) == original_tree == tree_manifest(app),
        "Delta round-trip did not reproduce every signed application file.",
    )
    verify_application(reconstructed, info)
    require(
        destination.is_file()
        and not destination.is_symlink()
        and destination.stat().st_size > 0,
        "Sparkle produced an invalid delta file.",
    )
    if destination.stat().st_size >= archive.stat().st_size:
        print(
            "Verified delta is not smaller than the full archive; offering only the full update."
        )
        return None
    executable = old_framework / "Sparkle"
    require(
        executable.is_file() and not executable.is_symlink(),
        "Invalid embedded Sparkle executable.",
    )
    locales = sorted(
        path.stem
        for path in (old_framework / "Resources").glob("*.lproj")
        if path.is_dir()
    )
    attributes = {
        SPARKLE + "deltaFrom": old_info["CFBundleVersion"],
        SPARKLE + "deltaFromSparkleExecutableSize": str(executable.stat().st_size),
    }
    if locales:
        attributes[SPARKLE + "deltaFromSparkleLocales"] = ",".join(locales)
    return destination, attributes

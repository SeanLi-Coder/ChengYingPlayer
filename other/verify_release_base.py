"""Authenticate one downloaded full release as a future verification base.

This local-only tool does not verify public delivery, deltas, installation, or
runtime behavior. It never launches the application or a bundled helper.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "other"))

from build_delta_update import detach_verification_volume, verify_application
from test_app_workspace import TestAppWorkspace
from verify_appcast import require, validate_info, verify, version_tuple


def sha(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def read_regular(path, maximum_size):
    """Read only a bounded regular input, refusing a replaced final symlink."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and not path.is_symlink(),
                "Verification input must be a regular, non-symlink file.")
        require(0 < before.st_size <= maximum_size, "Verification input size is invalid.")
        data = source.read(maximum_size + 1)
        after = os.fstat(source.fileno())
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                and len(data) == before.st_size, "Verification input changed while reading.")
        require(path.stat().st_dev == before.st_dev and path.stat().st_ino == before.st_ino,
                "Verification input path changed while reading.")
        return data


def copy_regular(source, destination, maximum_size):
    """Retain an independent archive copy without modifying or deleting the input."""
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 < before.st_size <= maximum_size,
                "Archive input must be a bounded regular file.")
        with destination.open("xb") as output:
            received = 0
            started = time.monotonic()
            while True:
                require(time.monotonic() - started < 300, "Archive copy timed out.")
                chunk = stream.read(min(1024 * 1024, before.st_size - received + 1))
                if not chunk:
                    break
                received += len(chunk)
                require(received <= before.st_size, "Archive input grew while copying.")
                output.write(chunk)
        after = os.fstat(stream.fileno())
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                and destination.stat().st_size == before.st_size,
                "Archive input changed while copying.")


def write_new(path, data):
    with path.open("xb") as output:
        output.write(data)


def verify_base(args):
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag), "Expected a stable release tag.")
    require(re.fullmatch(r"[1-9][0-9]*", args.build), "Expected a positive numeric build.")
    inputs = args.input_directory.resolve(strict=True)
    previous = args.previous_info_plist
    require(previous.is_file() and not previous.is_symlink(), "Independent trusted previous plist is required.")
    require(not previous.resolve(strict=True).is_relative_to(inputs),
            "Previous trust must be independent of the downloaded candidate directory.")
    previous_bytes = read_regular(previous, 1024 * 1024)
    previous_info = plistlib.loads(previous_bytes)
    require(isinstance(previous_info, dict), "Invalid previous application metadata.")
    previous_version = previous_info.get("CFBundleShortVersionString")
    require(isinstance(previous_version, str), "Missing previous trusted version.")
    previous_tag = "v" + previous_version
    key = validate_info(previous_info, previous_tag)
    require(int(previous_info["CFBundleVersion"]) < int(args.build)
            and version_tuple(previous_version) < version_tuple(args.tag[1:]),
            "The independently trusted application must precede the requested release.")
    expected = dict(previous_info, CFBundleShortVersionString=args.tag[1:], CFBundleVersion=args.build)
    validate_info(expected, args.tag)
    args.output_parent.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix=f"release-{args.tag}-base.",
                                        dir=args.output_parent.resolve(strict=True)))
    print(f"Base verification evidence: {destination}", flush=True)
    report = {
        "schema": 1, "scope": "authenticated-full-archive-base", "status": "incomplete",
        "tag": args.tag, "build": args.build,
        "previous_tag": previous_tag, "previous_build": previous_info["CFBundleVersion"],
        "archive_authenticated": False, "application_verified": False,
        "trusted_metadata_exported": False, "volumes_detached": False, "test_apps_cleaned": False,
        "public_delivery": "not-checked", "deltas": "not-checked",
        "installation": "not-checked", "application_runtime": "not-run", "helper_runtime": "not-run",
        "stage": "retain-inputs",
    }
    try:
        write_new(destination / "previous-trusted-app-info.plist", previous_bytes)
        feed = destination / "appcast.xml"
        write_new(feed, read_regular(inputs / "appcast.xml", 1024 * 1024))
        archive = destination / f"ChengYingPlayer-{args.tag}-Apple-Silicon.dmg"
        copy_regular(inputs / archive.name, archive, 4 * 1024**3)
        report["feed_sha256"] = sha(feed)
        report["archive"] = {"name": archive.name, "size": archive.stat().st_size, "sha256": sha(archive)}
        report["previous_trusted_info_sha256"] = hashlib.sha256(previous_bytes).hexdigest()
        report["stage"] = "authenticate-before-mount"
        # Historical full-base authentication intentionally makes no delta claim.
        # Trust originates only in the separately supplied previous plist.
        verify(feed, archive, expected, args.tag, verify_deltas=False)
        report["archive_authenticated"] = True
        with TestAppWorkspace(prefix="base-", dir=destination) as workspace:
            mount = Path(workspace) / "authenticated-volume"
            mount.mkdir()
            mounted = False
            try:
                report["stage"] = "mount-authenticated-archive"
                subprocess.run([
                    "hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                    "-mountpoint", str(mount), str(archive),
                ], check=True, capture_output=True, timeout=120)
                mounted = True
                require(sorted(path.name for path in mount.glob("*.app")) == ["ChengYing.app"],
                        "Authenticated volume has an unexpected application inventory.")
                app = mount / "ChengYing.app"
                info_path = app / "Contents/Info.plist"
                require(app.is_dir() and not app.is_symlink()
                        and info_path.resolve(strict=True).is_relative_to(app),
                        "Application metadata escapes the authenticated bundle.")
                report["stage"] = "verify-application"
                raw_info = read_regular(info_path, 1024 * 1024)
                actual_info = plistlib.loads(raw_info)
                require(isinstance(actual_info, dict), "Invalid application metadata.")
                require(validate_info(actual_info, args.tag) == key
                        and actual_info["CFBundleVersion"] == args.build,
                        "Actual application changed the expected version, build, identity, or update trust.")
                verify_application(app, actual_info)
                verify(feed, archive, actual_info, args.tag, verify_deltas=False)
                require(read_regular(info_path, 1024 * 1024) == raw_info,
                        "Application metadata changed during code signature verification.")
                require(sha(archive) == report["archive"]["sha256"]
                        and sha(feed) == report["feed_sha256"],
                        "Authenticated inputs changed during verification.")
                report["application_verified"] = True
                report["stage"] = "export-trusted-metadata"
                write_new(destination / "trusted-app-info.plist", raw_info)
                report["trusted_metadata_exported"] = True
                report["trusted_info_sha256"] = hashlib.sha256(raw_info).hexdigest()
            except BaseException:
                report["verification_failure_stage"] = report["stage"]
                raise
            finally:
                if mounted or os.path.ismount(mount):
                    report["stage"] = "detach-volume"
                    detach_verification_volume(mount, sys.exception())
                    report["volumes_detached"] = True
            report["stage"] = "retire-workspace"
        report["test_apps_cleaned"] = True
        report["stage"] = "complete"
        report["status"] = "verified-base"
    except BaseException as error:
        report["status"] = "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        write_new(destination / "base-verification.json", (json.dumps(report, indent=2) + "\n").encode())
    return destination, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--input-directory", type=Path, required=True)
    parser.add_argument("--previous-info-plist", type=Path, required=True)
    parser.add_argument("--output-parent", type=Path, default=ROOT / "build/ReleaseVerification.noindex")
    args = parser.parse_args()
    _, report = verify_base(args)
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for termination_signal in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(termination_signal, interrupted)
    main()

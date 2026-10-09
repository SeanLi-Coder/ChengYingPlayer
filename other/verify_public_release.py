"""Verify public release delivery in an automatically retired app workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "other"))

from test_app_workspace import TestAppWorkspace, unregister_test_apps
from build_delta_update import tree_manifest, verify_application
from release_delivery import ReleaseRedirects, asset_names, public_request, safe_url
from verify_appcast import (
    FEED_URL,
    RELEASES,
    delta_enclosures,
    require,
    validate_info,
    validate_update_settings,
    verify,
    verify_feed_signature,
)

COOKIE_SELF_TEST = "macos-v10-aes-and-fixed-diagnostics-verified-offline"
PROFILE_SELF_TEST = "synthetic-directories-and-explicit-selection-verified-offline"
LOGIN_SELF_TEST = "removed-entry-and-legacy-identity-verified-offline"


def run(arguments, timeout=300, *, env=None):
    return subprocess.run(
        arguments, check=True, capture_output=True, timeout=timeout, env=env
    ).stdout


def fetch(url, path, expected_size=None):
    if expected_size is None:
        body, _ = public_request(url)
        with path.open("xb") as output:
            output.write(body)
        return
    require(type(expected_size) is int and 0 < expected_size <= 4 * 1024**3,
            "Unexpected public installation payload size.")
    require(safe_url(url), "Unexpected public installation URL.")
    request = urllib.request.Request(url, headers={
        "User-Agent": "ChengYing-Update-Delivery-Check", "Cache-Control": "no-cache",
    })
    opener = urllib.request.build_opener(ReleaseRedirects())
    received = 0
    started = time.monotonic()
    with opener.open(request, timeout=20) as response, path.open("xb") as output:
        require(response.status == 200, "Public installation download failed.")
        while True:
            require(time.monotonic() - started < 300, "Public download timed out.")
            chunk = response.read1(min(1024 * 1024, expected_size - received + 1))
            require(time.monotonic() - started < 300, "Public download timed out.")
            if not chunk:
                break
            received += len(chunk)
            require(received <= expected_size, "Public download exceeds its expected size.")
            output.write(chunk)
    require(received == expected_size, "Public download is incomplete.")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_public_helper(app, info, expected_tree, output, expected_helper_build_id):
    helper = app / (
        "Contents/Helpers/DownloadCenter.app/Contents/MacOS/"
        "chengying-download-center-helper"
    )
    environment = os.environ.copy()
    environment["PATH"] = str(helper.parent) + ":" + environment.get(
        "PATH", "/usr/bin:/bin:/usr/sbin:/sbin"
    )
    # This entry point does not start the application/server, use user state,
    # launch Chrome, contact websites, or query the actual keychain.
    data = run([str(helper), "--self-test"], timeout=180, env=environment)
    result = json.loads(data)
    require(result.get("status") == "ok", "Public frozen helper self-test failed.")
    require(result.get("chrome_cookies") == COOKIE_SELF_TEST,
            "Public helper did not pass the new offline Chrome-cookie verification.")
    require(result.get("chrome_cookie_snapshot") == "wal-and-malformed-data-verified-offline",
            "Public helper missed the new WAL and malformed-cookie verification.")
    require(result.get("chrome_profiles") == PROFILE_SELF_TEST,
            "Public helper missed the offline Chrome-profile selection verification.")
    require(result.get("dedicated_login") == LOGIN_SELF_TEST,
            "Public helper missed the retired login entry and legacy identity verification.")
    require(result.get("diagnostic_log") == "bounded-redacted-export-verified-offline",
            "Public helper did not pass the new diagnostic privacy verification.")
    identity = result.get("diagnostic_identity", {})
    require(identity.get("player_version") == info["CFBundleShortVersionString"]
            and identity.get("player_build") == info["CFBundleVersion"]
            and identity.get("identity_source") == "bundled"
            and identity.get("helper_build_id") == expected_helper_build_id,
            "Public diagnostic identity differs from the actual installed application.")
    api_report = run([
        sys.executable, "-B", str(ROOT / "Tools/DownloaderHelper/smoke_helper.py"),
        "--helper", str(helper), "--ffmpeg", str(app / "Contents/MacOS/ffmpeg"),
        "--ffprobe", str(app / "Contents/MacOS/ffprobe"),
    ], timeout=180, env=environment)
    (output.parent / (output.stem + "-diagnostic-api.log")).write_bytes(api_report)
    clip_report = run([
        sys.executable, "-B", str(ROOT / "Tools/VideoToolsTests/app_dolby_clip_smoke.py"),
        "--app", str(app),
    ], timeout=300)
    require(b"PASS: frozen clips retain complete RPU data" in clip_report,
            "Public frozen Dolby Vision clipping smoke did not complete.")
    (output.parent / (output.stem + "-dolby-clip.log")).write_bytes(clip_report)
    hdr10plus_report = run([
        sys.executable, "-B", str(ROOT / "Tools/VideoToolsTests/app_hdr10plus_clip_smoke.py"),
        "--app", str(app),
    ], timeout=300)
    require(b"PASS: frozen clips retain complete HDR10+ payloads" in hdr10plus_report,
            "Public frozen HDR10+ clipping smoke did not complete.")
    (output.parent / (output.stem + "-hdr10plus-clip.log")).write_bytes(hdr10plus_report)
    require(tree_manifest(app) == expected_tree, "Frozen helper self-test changed the app tree.")
    verify_application(app, info)
    output.write_text(json.dumps(result, indent=2) + "\n")
    return {
        "status": result["status"], "chrome_cookies": result["chrome_cookies"],
        "chrome_cookie_snapshot": result["chrome_cookie_snapshot"],
        "chrome_profiles": result["chrome_profiles"],
        "dedicated_login": result["dedicated_login"],
        "dolby_clip": "precise-complete-rpu-audio-verified",
        "hdr10plus_clip": "precise-complete-t35-audio-verified",
        "diagnostic_log": result["diagnostic_log"], "diagnostic_identity": identity,
        "diagnostic_api": "authenticated-readonly-private-export-verified",
    }


def verify_at(destination, working, args):
    TAG, BUILD = args.tag, args.build
    OLD, DELTA_TOOL = args.previous_directory, args.delta_tool
    OLD_INFO = OLD / "trusted-app-info.plist"
    require(OLD_INFO.is_file() and not OLD_INFO.is_symlink(),
            "Previous verified trusted-app-info.plist is required.")
    old_identity = plistlib.loads(OLD_INFO.read_bytes())
    OLD_TAG = "v" + old_identity["CFBundleShortVersionString"]
    OLD_BUILD = old_identity["CFBundleVersion"]

    metadata = json.loads(public_request(
        f"https://api.github.com/repos/SeanLi-Coder/ChengYingPlayer/releases/tags/{TAG}"
    )[0])
    require(metadata["tag_name"] == TAG and not metadata["draft"] and not metadata["prerelease"],
            "Expected the requested published stable release.")
    (destination / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    latest = json.loads(public_request(
        "https://api.github.com/repos/SeanLi-Coder/ChengYingPlayer/releases/latest"
    )[0])
    require(latest.get("tag_name") == TAG and latest.get("draft") is False
            and latest.get("prerelease") is False,
            "Anonymous latest does not match the requested release.")
    fetch(FEED_URL, destination / "appcast.xml")
    fetch(RELEASES + "/download/" + TAG + "/appcast.xml", destination / "tagged-appcast.xml")
    feed = (destination / "appcast.xml").read_bytes()
    require(feed == (destination / "tagged-appcast.xml").read_bytes(),
            "The installed-app feed and immutable tagged feed differ.")

    old_info = plistlib.loads(OLD_INFO.read_bytes())
    key = validate_info(old_info, OLD_TAG)
    require(old_info["CFBundleVersion"] == OLD_BUILD, "Unexpected trusted previous build.")
    content = verify_feed_signature(feed, key)
    expected_info = {**old_info, "CFBundleShortVersionString": TAG[1:], "CFBundleVersion": BUILD}
    assets = {asset["name"]: asset for asset in metadata["assets"]}
    require(len(assets) == len(metadata["assets"]) and set(assets) == set(asset_names(TAG, feed)),
            "Public release assets are missing, duplicated, or unexpected.")
    require(all(asset["state"] == "uploaded" for asset in assets.values()),
            "A public release asset is not uploaded.")
    deltas = delta_enclosures(content, TAG)
    require(all(delta["from_build"] == OLD_BUILD for delta in deltas),
            "An advertised delta needs an additional authenticated base archive.")
    payloads = [f"ChengYingPlayer-{TAG}-Apple-Silicon.dmg", *(delta["name"] for delta in deltas)]
    results = {}
    for name in payloads:
        print(f"Downloading and verifying public payload: {name}", flush=True)
        fetch(RELEASES + "/download/" + TAG + "/" + name, destination / name, assets[name]["size"])
        fetch(RELEASES + "/download/" + TAG + "/" + name + ".sha256", destination / (name + ".sha256"))
        digest = sha(destination / name)
        require((destination / (name + ".sha256")).read_bytes() == f"{digest}  {name}\n".encode(),
                "Anonymous checksum does not match downloaded payload bytes.")
        for asset_name in (name, name + ".sha256"):
            local = destination / asset_name
            require(local.stat().st_size == assets[asset_name]["size"], "Anonymous asset size mismatch.")
            require("sha256:" + sha(local) == assets[asset_name]["digest"], "Anonymous asset hash mismatch.")
        results[name] = {"size": (destination / name).stat().st_size, "sha256": digest}
    require("sha256:" + sha(destination / "appcast.xml") == assets["appcast.xml"]["digest"],
            "Anonymous feed hash mismatch.")
    require((destination / "appcast.xml").stat().st_size == assets["appcast.xml"]["size"],
            "Anonymous feed size mismatch.")

    new_dmg = destination / payloads[0]
    old_dmg = OLD / f"ChengYingPlayer-{OLD_TAG}-Apple-Silicon.dmg"
    # Authenticate both full archives and every new delta with the previous
    # installed app's trusted key before mounting or applying any archive.
    print("Verifying archive signatures with the previous stable public key.", flush=True)
    verify(destination / "appcast.xml", new_dmg, expected_info, TAG)
    verify(OLD / "appcast.xml", old_dmg, old_info, OLD_TAG, verify_deltas=False)
    mounted = []
    helper_results = {}
    try:
        for label, archive in (("new", new_dmg), ("old", old_dmg)):
            print(f"Mounting authenticated {label} archive read-only.", flush=True)
            mount = working / (label + "-volume")
            mount.mkdir()
            mounted.append(mount)
            run([
                "hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", str(mount), str(archive),
            ], timeout=120)
            require(sorted(path.name for path in mount.glob("*.app")) == ["ChengYing.app"],
                    "A release volume has an unexpected application inventory.")
        new_app = working / "new-volume/ChengYing.app"
        old_app = working / "old-volume/ChengYing.app"
        actual_info = plistlib.loads((new_app / "Contents/Info.plist").read_bytes())
        require(actual_info["CFBundleVersion"] == BUILD, "The new application build is not the requested build.")
        require(validate_update_settings(actual_info) == key, "The new application changed update trust.")
        require(plistlib.loads((old_app / "Contents/Info.plist").read_bytes()) == old_info,
                "The authenticated previous application differs from its trusted plist.")
        verify_application(new_app, actual_info)
        verify_application(old_app, old_info)
        verify(destination / "appcast.xml", new_dmg, actual_info, TAG)
        (destination / "trusted-app-info.plist").write_bytes(
            (new_app / "Contents/Info.plist").read_bytes()
        )
        expected_tree = tree_manifest(new_app)
        for delta in deltas:
            print(f"Applying and comparing public delta from build {delta['from_build']}.", flush=True)
            label = "reconstructed-from-" + delta["from_build"]
            rebuilt = working / label / "ChengYing.app"
            rebuilt.parent.mkdir()
            run([
                str(DELTA_TOOL), "apply", str(old_app), str(rebuilt), str(destination / delta["name"]),
            ], timeout=900)
            verify_application(rebuilt, actual_info)
            require(tree_manifest(rebuilt) == expected_tree,
                    "Public delta reconstruction differs from the complete signed application.")
            helper_results[label] = verify_public_helper(
                rebuilt, actual_info, expected_tree, destination / (label + "-helper-self-test.json"), args.helper_build_id
            )
            print("Public delta tree, code signatures and frozen helper verified.", flush=True)
        if not deltas:
            # A full-only update still needs the public frozen-runtime check.
            copied = working / "full-copy/ChengYing.app"
            copied.parent.mkdir()
            run(["ditto", str(new_app), str(copied)], timeout=300)
            require(tree_manifest(copied) == expected_tree, "Full application copy differs from its archive.")
            helper_results["full-copy"] = verify_public_helper(
                copied, actual_info, expected_tree, destination / "full-copy-helper-self-test.json", args.helper_build_id
            )
    finally:
        primary_error = sys.exception()
        cleanup_errors = []
        for mount in reversed(mounted):
            if not os.path.ismount(mount):
                continue
            try:
                unregister_test_apps(mount)
            except BaseException as error:
                cleanup_errors.append(error)
            try:
                run(["hdiutil", "detach", "-quiet", str(mount)], timeout=120)
            except BaseException as error:
                cleanup_errors.append(error)
        if cleanup_errors:
            if primary_error is not None:
                cleanup_errors.insert(0, primary_error)
            raise BaseExceptionGroup("Public verification volume cleanup failed.", cleanup_errors)
    summary = {
        "tag": TAG, "build": BUILD, "published_at": metadata["published_at"],
        "asset_count": len(assets), "feed_sha256": sha(destination / "appcast.xml"),
        "anonymous_latest_and_payloads": True, "old_key_verified": True,
        "delta_count": len(deltas), "roundtrip_identical": True if deltas else None,
        "volumes_detached": True, "payloads": results,
        "public_frozen_helper_self_tests": helper_results,
    }
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--previous-directory", required=True, type=Path)
    parser.add_argument("--delta-tool", required=True, type=Path)
    parser.add_argument("--helper-build-id", required=True)
    parser.add_argument("--output-parent", type=Path,
                        default=ROOT / "build/ReleaseVerification.noindex")
    args = parser.parse_args()
    require(args.tag.isascii() and args.tag.startswith("v") and all(part.isdigit() for part in args.tag[1:].split("."))
            and len(args.tag[1:].split(".")) == 3, "Expected a stable version tag.")
    require(args.build.isascii() and args.build.isdigit(), "Expected a numeric build.")
    require(len(args.helper_build_id) == 64
            and all(character in "0123456789abcdef" for character in args.helper_build_id),
            "Expected a SHA-256 helper build identity.")
    args.previous_directory = args.previous_directory.resolve(strict=True)
    args.delta_tool = args.delta_tool.resolve(strict=True)
    args.output_parent.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix=f"release-{args.tag}-public.",
                                        dir=args.output_parent.resolve(strict=True)))
    print(f"Public verification reports: {destination}", flush=True)
    # Only archives and evidence persist. Every mounted or expanded app is owned
    # by this context and must be unregistered and removed before success.
    with TestAppWorkspace(prefix="install-", dir=destination) as directory:
        summary = verify_at(destination, Path(directory), args)
    summary["test_apps_cleaned"] = True
    (destination / "verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    for termination_signal in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(termination_signal, interrupted)
    main()

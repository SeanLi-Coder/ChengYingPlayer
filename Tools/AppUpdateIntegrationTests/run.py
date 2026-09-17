"""Replace and relaunch a disposable app using real Sparkle and the production UI."""

from __future__ import annotations

import argparse
import functools
import hashlib
import http.server
import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scenario",
        choices=("upgrade", "tampered-dmg", "phase-observer"),
        default="upgrade",
        help="Exercise replacement, archive rejection, or same-turn driver observation.",
    )
    scenario = parser.parse_args().scenario
    os.environ.pop("SPARKLE_ED25519_PRIVATE_KEY", None)
    sparkle = Path(os.environ["SPARKLE_TEST_ROOT"])
    framework_root = sparkle / "Sparkle.xcframework/macos-arm64_x86_64"
    framework_source = framework_root / "Sparkle.framework"
    if installed_app := os.environ.get("SPARKLE_INSTALLED_APP"):
        framework_source = Path(installed_app) / "Contents/Frameworks/Sparkle.framework"
    run("codesign", "--verify", "--deep", "--strict", str(framework_source))
    with tempfile.TemporaryDirectory(prefix="chengying-upgrade-e2e-") as temporary:
        work = Path(temporary).resolve()
        hosted = work / "hosted"
        hosted.mkdir()
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(hosted))
        )
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base_url = f"http://127.0.0.1:{server.server_port}"
        run(
            "xcrun",
            "swiftc",
            str(ROOT / "Tools/SparkleUpdateTests/FixtureKey.swift"),
            "-o",
            str(work / "key"),
        )
        run(str(work / "key"), str(work))
        identifier = "org.chengying.tests.realupgrade." + uuid.uuid4().hex
        journal = work / "journal.txt"
        old_app = work / "installed/UpdateFixture.app"
        content = old_app / "Contents"
        (content / "MacOS").mkdir(parents=True)
        (content / "Frameworks").mkdir()
        run(
            "ditto",
            str(framework_source),
            str(content / "Frameworks/Sparkle.framework"),
        )
        for language in ("en", "zh-Hans", "zh-Hant"):
            target = content / f"Resources/{language}.lproj"
            target.mkdir(parents=True)
            shutil.copyfile(
                ROOT / f"iina/{language}.lproj/Updates.strings",
                target / "Updates.strings",
            )
        sources = [
            ROOT / "iina/Updates" / name
            for name in (
                "UpdatePolicy.swift",
                "AppUpdateWindowController.swift",
                "AppUpdateUserDriver.swift",
            )
        ]
        run(
            "xcrun",
            "swiftc",
            "-target",
            "arm64-apple-macos12",
            "-F",
            str(framework_root),
            "-framework",
            "Sparkle",
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            "@executable_path/../Frameworks",
            *map(str, sources),
            str(Path(__file__).with_name("ObservedUserDriver.swift")),
            str(Path(__file__).with_name("ObserverRegression.swift")),
            str(Path(__file__).with_name("main.swift")),
            "-o",
            str(content / "MacOS/UpdateFixture"),
        )
        info = {
            "CFBundleIdentifier": identifier,
            "CFBundleName": "UpdateFixture",
            "CFBundleExecutable": "UpdateFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "12.0",
            "LSUIElement": True,
            "FixtureJournal": str(journal),
            "SUFeedURL": base_url + "/appcast.xml",
            "SUPublicEDKey": (work / "test-public").read_text(),
            "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableAutomaticChecks": True,
            "SUAllowsAutomaticUpdates": True,
            "SUAutomaticallyUpdate": False,
            "SUEnableSystemProfiling": False,
            # Local-only fixture exception; never used by the shipping application.
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }
        (content / "Info.plist").write_bytes(plistlib.dumps(info))
        new_app = work / "volume/UpdateFixture.app"
        new_app.parent.mkdir()
        run("ditto", str(old_app), str(new_app))
        new_info = dict(info, CFBundleVersion="2", CFBundleShortVersionString="2.0")
        (new_app / "Contents/Info.plist").write_bytes(plistlib.dumps(new_info))
        for app in (old_app, new_app):
            run(
                "codesign",
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                "--entitlements",
                str(ROOT / "iina/IINA.entitlements"),
                str(app),
            )
            run("codesign", "--verify", "--deep", "--strict", str(app))
        run(str(content / "MacOS/UpdateFixture"), "--phase-observer-regression")
        if scenario == "phase-observer":
            server.shutdown()
            server.server_close()
            return
        original_files = {
            relative: hashlib.sha256((content / relative).read_bytes()).digest()
            for relative in ("Info.plist", "MacOS/UpdateFixture")
        }
        archive = hosted / "UpdateFixture.dmg"
        run(
            "hdiutil",
            "create",
            "-quiet",
            "-srcfolder",
            str(new_app.parent),
            "-format",
            "UDZO",
            str(archive),
        )
        run(
            str(sparkle / "bin/generate_appcast"),
            "--ed-key-file",
            "-",
            "--maximum-deltas",
            "0",
            "--download-url-prefix",
            base_url + "/",
            str(hosted),
            input=(work / "test-seed").read_bytes(),
            capture_output=True,
        )
        if scenario == "tampered-dmg":
            # Sign the feed and original archive first, then alter only one payload byte.
            original = archive.read_bytes()
            altered = bytearray(original)
            altered[len(altered) // 2] ^= 1
            archive.write_bytes(altered)
            if archive.stat().st_size != len(original) or altered == original:
                raise RuntimeError(
                    "The negative fixture did not preserve the archive length."
                )
        log_path = work / "process.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(content / "MacOS/UpdateFixture")], stdout=log, stderr=log
            )
            try:
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    events = journal.read_text() if journal.exists() else ""
                    if "replacement-relaunched" in events or "failure:" in events:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(
                        "Timed out waiting for the real updater to relaunch."
                    )
                print(events)
                if scenario == "tampered-dmg":
                    if process.wait(timeout=15) != 0:
                        raise RuntimeError(
                            "The fixture crashed while rejecting the archive."
                        )
                    # Give any unintended relaunch a chance to become observable.
                    time.sleep(1)
                    events = journal.read_text()
                    for required in (
                        "launched:1:",
                        "valid-update:2",
                        "download-completed",
                        "signature-rejected",
                    ):
                        if required not in events:
                            raise RuntimeError(
                                f"Missing archive-rejection event: {required}"
                            )
                    for forbidden in (
                        "gate-acquired",
                        "barrier:true",
                        "phase:waiting",
                        "launched:2:",
                        "replacement-relaunched",
                    ):
                        if forbidden in events:
                            raise RuntimeError(
                                f"Unsafe action after archive tampering: {forbidden}"
                            )
                    if (
                        sum(
                            line.startswith("launched:") for line in events.splitlines()
                        )
                        != 1
                    ):
                        raise RuntimeError(
                            "The rejected update restarted the fixture application."
                        )
                    with (content / "Info.plist").open("rb") as stream:
                        if plistlib.load(stream)["CFBundleVersion"] != "1":
                            raise RuntimeError(
                                "The invalid archive replaced the installed version."
                            )
                    for relative, digest in original_files.items():
                        if (
                            hashlib.sha256((content / relative).read_bytes()).digest()
                            != digest
                        ):
                            raise RuntimeError(
                                f"The invalid archive modified the installed {relative}."
                            )
                    run("codesign", "--verify", "--deep", "--strict", str(old_app))
                    print(
                        "PASS: Valid signed feed, same-length tampered DMG rejected; "
                        "installed version 1 unchanged, no restart, and no acquired gate."
                    )
                    return
                for required in (
                    "launched:1:",
                    "phase:downloading",
                    "download-visible:true",
                    "download-completed",
                    "phase:waiting",
                    "barrier:true",
                    "launched:2:",
                    "replacement-relaunched",
                ):
                    if required not in events:
                        raise RuntimeError(f"Missing real upgrade event: {required}")
                with (content / "Info.plist").open("rb") as stream:
                    if plistlib.load(stream)["CFBundleVersion"] != "2":
                        raise RuntimeError("The installed bundle was not replaced.")
                run("codesign", "--verify", "--deep", "--strict", str(old_app))
                print(
                    "PASS: Signed feed, verified DMG, visible download, idle barrier, real replacement and relaunch."
                )
            except BaseException:
                print(log_path.read_text(errors="replace"))
                if journal.exists():
                    print(journal.read_text())
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=15)
                # The unique fixture domain never shares the real app's preferences.
                subprocess.run(
                    ["defaults", "delete", identifier], capture_output=True, check=False
                )
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    main()

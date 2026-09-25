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
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
SPARKLE_XML = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DELTA_SCENARIOS = {
    "delta-upgrade",
    "tampered-delta",
    "mismatched-delta",
    "tampered-delta-and-dmg",
}
REJECTED_SCENARIOS = {"tampered-dmg", "tampered-delta-and-dmg"}
ET.register_namespace("sparkle", SPARKLE_XML)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        self.server.request_paths.append(path)
        if path == "/UpdateFixture.dmg" and self.server.before_full_download:
            try:
                self.server.before_full_download()
            except (OSError, RuntimeError) as error:
                self.server.safety_failures.append(str(error))
        super().do_GET()

    def log_message(self, *_args):
        pass


def snapshot(directory):
    """Compare fixture data without following any external symlink."""
    return {
        str(path.relative_to(directory)): (
            ("symlink", os.readlink(path))
            if path.is_symlink()
            else ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        )
        for path in directory.rglob("*")
        if path.is_symlink() or path.is_file()
    }


def resign(app):
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


def sign_file(sparkle, path, seed, *, signature_only=False):
    options = ["-p"] if signature_only else []
    return (
        run(
            str(sparkle / "bin/sign_update"),
            "--ed-key-file",
            "-",
            *options,
            str(path),
            input=seed,
            capture_output=True,
        )
        .stdout.decode()
        .strip()
    )


def corrupt_payload(path):
    original = path.read_bytes()
    altered = bytearray(original)
    altered[len(altered) // 2] ^= 1
    path.write_bytes(altered)
    if path.stat().st_size != len(original) or altered == original:
        raise RuntimeError("The negative fixture did not preserve the archive length.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scenario",
        choices=("upgrade", "tampered-dmg", "phase-observer", *sorted(DELTA_SCENARIOS)),
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
        server.request_paths = []
        server.safety_failures = []
        server.before_full_download = None
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
        # All support files are synthetic and live outside either fixture app bundle.
        support = work / "Library/Application Support" / identifier
        support.mkdir(parents=True)
        support_values = {
            "settings.json": b'{"language":"zh-Hans","volume":13,"hdr":false}',
            "keybindings.conf": b"c multiply speed 1.1\n",
            "bookmarks.plist": plistlib.dumps(
                {"SyntheticBookmark": b"fixture-bookmark"}
            ),
            "download-history.json": b'[{"id":"fixture-complete","status":"completed"}]',
            "models/fixture-model/weights.bin": os.urandom(4096),
            "models/fixture-model/ready.json": b'{"verified":true,"fixture":true}',
        }
        for relative, value in support_values.items():
            target = support / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)
        original_support = snapshot(support)
        preferences = {
            "volume": 13,
            "enableHdrSupport": False,
            "FixtureSubtitleSize": 47,
            "FixtureScreenshotDirectory": str(work / "saved-screenshots"),
            "FixtureShortcut": "Meta+Shift+r",
            "inputConfigs": {"Fixture": str(support / "keybindings.conf")},
            "FixtureBookmark": b"synthetic-security-scoped-bookmark",
            "FixturePlaybackSpeed": 1.3,
            "FixtureFolderSort": ["name", "ascending"],
            "FixtureProxy": "http://127.0.0.1:17897",
            "SUEnableAutomaticChecks": False,
            "SUAutomaticallyUpdate": False,
        }
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
        (content / "Resources/UnchangedPayload.bin").write_bytes(
            os.urandom(2 * 1024 * 1024)
        )
        (content / "Resources/VersionMarker.txt").write_text("fixture-version-one\n")
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
            "FixturePreferences": preferences,
            "FixtureSupportDirectory": str(support),
            "FixtureSupportHashes": {
                relative: hashlib.sha256(value).hexdigest()
                for relative, value in support_values.items()
            },
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
        (new_app / "Contents/Resources/VersionMarker.txt").write_text(
            "fixture-version-two\n"
        )
        for app in (old_app, new_app):
            resign(app)
        run(str(content / "MacOS/UpdateFixture"), "--phase-observer-regression")
        if scenario == "phase-observer":
            server.shutdown()
            server.server_close()
            return
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
        if scenario in DELTA_SCENARIOS:
            delta = hosted / "UpdateFixture-2-from-1.delta"
            run(
                str(sparkle / "bin/BinaryDelta"),
                "create",
                "--version",
                "4",
                "--compression",
                "lzma",
                str(old_app),
                str(new_app),
                str(delta),
            )
            # The official patch must exactly reproduce the signed target before testing delivery.
            patched = work / "patch-verification/UpdateFixture.app"
            patched.parent.mkdir()
            run(
                str(sparkle / "bin/BinaryDelta"),
                "apply",
                str(old_app),
                str(patched),
                str(delta),
            )
            run("codesign", "--verify", "--deep", "--strict", str(patched))
            if snapshot(patched) != snapshot(new_app):
                raise RuntimeError(
                    "The generated delta did not reproduce the target bundle."
                )
            if delta.stat().st_size >= archive.stat().st_size:
                raise RuntimeError("The delta fixture does not save download bytes.")
            signature = sign_file(
                sparkle, delta, (work / "test-seed").read_bytes(), signature_only=True
            )
            feed = hosted / "appcast.xml"
            tree = ET.parse(feed)
            item = tree.getroot().find("channel/item")
            if item is None:
                raise RuntimeError("The fixture appcast has no update item.")
            deltas = ET.SubElement(item, f"{{{SPARKLE_XML}}}deltas")
            sparkle_version = content / "Frameworks/Sparkle.framework/Versions/B"
            locales = sorted(
                path.stem
                for path in (sparkle_version / "Resources").glob("*.lproj")
                if path.is_dir()
            )
            enclosure = ET.SubElement(
                deltas,
                "enclosure",
                {
                    "url": base_url + "/" + delta.name,
                    "length": str(delta.stat().st_size),
                    "type": "application/octet-stream",
                    f"{{{SPARKLE_XML}}}deltaFrom": "1",
                    f"{{{SPARKLE_XML}}}deltaFromSparkleExecutableSize": str(
                        (sparkle_version / "Sparkle").stat().st_size
                    ),
                    f"{{{SPARKLE_XML}}}edSignature": signature,
                },
            )
            if locales:
                enclosure.set(
                    f"{{{SPARKLE_XML}}}deltaFromSparkleLocales", ",".join(locales)
                )
            tree.write(feed, encoding="utf-8", xml_declaration=True)
            sign_file(sparkle, feed, (work / "test-seed").read_bytes())
            if scenario in {"tampered-delta", "tampered-delta-and-dmg"}:
                corrupt_payload(delta)
            elif scenario == "mismatched-delta":
                # A validly signed local variant shares version 1 but not the patch's tree hash.
                (content / "Resources/VersionMarker.txt").write_text(
                    "fixture-local-variant\n"
                )
                resign(old_app)
        original_bundle = snapshot(old_app)

        def assert_safe_before_fallback():
            events = journal.read_text() if journal.exists() else ""
            for forbidden in (
                "gate-acquired",
                "barrier:true",
                "phase:waiting",
                "launched:2:",
            ):
                if forbidden in events:
                    raise RuntimeError(
                        f"Unsafe action before verified fallback: {forbidden}"
                    )
            if snapshot(old_app) != original_bundle:
                raise RuntimeError(
                    "The delta failure modified the installed bundle before fallback."
                )

        if scenario in DELTA_SCENARIOS - {"delta-upgrade"}:
            server.before_full_download = assert_safe_before_fallback
        if scenario in REJECTED_SCENARIOS:
            # Sign the feed and original archive first, then alter only one payload byte.
            corrupt_payload(archive)
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
                if snapshot(support) != original_support:
                    raise RuntimeError(
                        "The update changed external settings, history, bookmarks, or model files."
                    )
                if (
                    "preferences-preserved:1" not in events
                    or "support-preserved:1" not in events
                ):
                    raise RuntimeError(
                        "The old fixture did not verify its original user data."
                    )
                if server.safety_failures:
                    raise RuntimeError("; ".join(server.safety_failures))
                payloads = [
                    path
                    for path in server.request_paths
                    if path.endswith((".delta", ".dmg"))
                ]
                delta_path = "/UpdateFixture-2-from-1.delta"
                expected_payloads = (
                    [delta_path]
                    if scenario == "delta-upgrade"
                    else [delta_path, "/UpdateFixture.dmg"]
                    if scenario in DELTA_SCENARIOS
                    else ["/UpdateFixture.dmg"]
                )
                if payloads != expected_payloads:
                    raise RuntimeError(
                        f"Unexpected update downloads: {payloads}; expected {expected_payloads}"
                    )
                print(f"PASS: Actual HTTP payload requests: {payloads}")
                if scenario in REJECTED_SCENARIOS:
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
                        "preferences-preserved:before-termination",
                        "support-preserved:before-termination",
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
                    if snapshot(old_app) != original_bundle:
                        raise RuntimeError(
                            "The invalid archive modified the installed bundle."
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
                    "preferences-preserved:before-termination",
                    "support-preserved:before-termination",
                    "launched:2:",
                    "preferences-preserved:2",
                    "support-preserved:2",
                    "replacement-relaunched",
                ):
                    if required not in events:
                        raise RuntimeError(f"Missing real upgrade event: {required}")
                with (content / "Info.plist").open("rb") as stream:
                    if plistlib.load(stream)["CFBundleVersion"] != "2":
                        raise RuntimeError("The installed bundle was not replaced.")
                run("codesign", "--verify", "--deep", "--strict", str(old_app))
                if snapshot(old_app) != snapshot(new_app):
                    raise RuntimeError(
                        "The installed bundle does not match the verified complete target."
                    )
                launches = [
                    line for line in events.splitlines() if line.startswith("launched:")
                ]
                if (
                    len(launches) != 2
                    or sum(line.startswith("launched:2:") for line in launches) != 1
                ):
                    raise RuntimeError(
                        "The upgrade did not perform exactly one replacement relaunch."
                    )
                print(
                    "PASS: Signed feed, verified payload, visible download, idle barrier, real replacement, "
                    "one relaunch, and preserved preferences, settings, bookmarks, history, and models."
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

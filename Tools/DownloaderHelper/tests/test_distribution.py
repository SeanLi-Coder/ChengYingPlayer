from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent


def normalized(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def test_runtime_lock_matches_proven_versions_and_artifact_hashes():
    manifest = json.loads((ROOT / "runtime-artifacts.json").read_text(encoding="utf-8"))
    assert manifest["python_version"] == "3.13.2"
    assert manifest["platform"] == "macos-arm64"
    assert manifest["minimum_macos"] == "13.5"
    assert manifest["upstream_commit"] == "e532e4fcd74bce4dfe730e49b8f1b49adceff62e"
    pattern = r"^([\w-]+)(?:\[[^\]]+\])?==([^\s]+)"
    inputs = dict(
        re.findall(
            pattern, (ROOT / "requirements-runtime.in").read_text(), re.MULTILINE
        )
    )
    locked = {
        normalized(name): (version, digest)
        for name, version, digest in re.findall(
            pattern + r" \\\n    --hash=sha256:([0-9a-f]{64})$",
            (ROOT / "requirements-runtime.txt").read_text(),
            re.MULTILINE,
        )
    }
    artifacts = manifest["artifacts"]
    assert len(inputs) == len(locked) == len(artifacts) == 33
    for package in artifacts:
        name = normalized(package["name"])
        assert (
            normalized(next(key for key in inputs if normalized(key) == name)) == name
        )
        assert (
            inputs[next(key for key in inputs if normalized(key) == name)]
            == package["version"]
        )
        assert locked[name] == (package["version"], package["sha256"])
        url = urlsplit(package["url"])
        assert url.scheme == "https" and url.hostname == "files.pythonhosted.org"
        assert url.path.endswith(".whl")
        assert url.username is None and url.password is None and not url.query


def test_license_collection_retains_every_runtime_and_nested_driver_notice(tmp_path):
    specification = importlib.util.spec_from_file_location(
        "download_distribution_licenses", ROOT / "collect_licenses.py"
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    destination = tmp_path / "Legal"
    module.collect(destination, ROOT)
    manifest = json.loads((ROOT / "runtime-artifacts.json").read_text())
    for package in manifest["artifacts"]:
        assert any(
            path.is_file()
            for path in (destination / normalized(package["name"])).rglob("*")
        )
    for relative in (
        "RednoteDownloader-MIT-LICENSE.txt",
        "runtime-artifacts.json",
        "DISTRIBUTION.md",
        "playwright/playwright/driver/LICENSE",
        "playwright/playwright/driver/package/NOTICE",
        "playwright/playwright/driver/package/lib/utilsBundle.js.LICENSE",
    ):
        assert (destination / relative).stat().st_size > 0


def test_onedir_build_includes_desktop_assets_and_uses_only_verified_vendor():
    build = (ROOT / "build_helper.sh").read_text()
    assert "--onedir --contents-directory _internal" in build
    assert "--onefile" not in build
    assert '--add-data "$SCRIPT_DIR/static:static"' in build
    assert '--add-data "$VENDOR_DIR:vendor/rednote"' in build
    assert '"$SCRIPT_DIR/verify_vendor.py"' in build
    assert "--exclude '__pycache__' --exclude '.pytest_cache'" in build
    assert "playwright install" not in build
    assert "-m pip" not in build


def test_runtime_permissions_are_scoped_to_helper_executables():
    import plistlib

    permissions = plistlib.loads((ROOT / "runtime-entitlements.plist").read_bytes())
    assert permissions["com.apple.security.cs.allow-jit"] is True
    assert permissions["com.apple.security.cs.disable-library-validation"] is True
    assert "com.apple.security.get-task-allow" not in permissions
    assert "com.apple.security.app-sandbox" not in permissions


def test_embedding_architecture_policy_uses_only_generated_helper_paths(tmp_path):
    project = tmp_path / "Project With Spaces"
    scripts = project / "other"
    scripts.mkdir(parents=True)
    script = scripts / "embed_download_center.sh"
    shutil.copyfile(ROOT.parents[1] / "other" / script.name, script)
    output = tmp_path / "Build With Spaces"
    contents = "Test Player.app/Contents"
    destination = output / contents / "Helpers" / "DownloadCenter"
    destination.mkdir(parents=True)
    (destination / "previous-arm-build").write_text("generated")
    preserved = destination.parent / "other-helper"
    preserved.write_text("preserved")
    environment = {
        **os.environ,
        "TARGET_BUILD_DIR": str(output),
        "CONTENTS_FOLDER_PATH": contents,
        "ARCHS": "x86_64",
    }
    intel = subprocess.run(
        ["bash", str(script)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert intel.returncode == 0, intel.stderr
    assert "Skipping" in intel.stdout
    assert not destination.exists()
    assert preserved.read_text() == "preserved"
    for architectures in ("arm64 x86_64", "", "i386"):
        environment["ARCHS"] = architectures
        result = subprocess.run(
            ["bash", str(script)],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 2
        assert "universal builds are not supported" in result.stderr
    environment["ARCHS"] = "arm64"
    missing = subprocess.run(
        ["bash", str(script)],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    assert missing.returncode == 2
    assert "Build the complete download center" in missing.stderr

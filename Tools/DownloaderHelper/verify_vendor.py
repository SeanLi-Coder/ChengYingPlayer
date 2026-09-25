#!/usr/bin/env python3
"""Verify the complete vendored downloader without importing its runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath

HELPER_ROOT = Path(__file__).resolve().parent
UPSTREAM_COMMIT = "e532e4fcd74bce4dfe730e49b8f1b49adceff62e"
UPSTREAM_VERSION = "1.2.23"
PATCHED_FILES = {
    "app/main.py", "app/models.py", "app/platforms.py", "app/downloader.py",
    "app/task_manager.py", "app/static/app.js", "app/static/index.html",
    "app/browser.py", "app/douyin_signing.py",
    "tests/test_stop.py", "tests/test_signing_diagnostics.py",
}
INTEGRATION_FILES = {"app/kuaishou.py"}
IGNORED_CACHE_DIRECTORIES = {"__pycache__", ".pytest_cache"}


def verify_vendor(
    vendor_root: Path | None = None, manifest_path: Path | None = None
) -> list[str]:
    """Return integrity errors; never import application code or read user data."""
    vendor_root = vendor_root or HELPER_ROOT / "vendor" / "rednote"
    manifest_path = manifest_path or HELPER_ROOT / "upstream-manifest.json"
    errors: list[str] = []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ["The upstream manifest is missing or invalid."]
    if not isinstance(manifest, dict):
        return ["The upstream manifest must be an object."]
    if manifest.get("schema_version") != 2:
        errors.append("Unsupported manifest schema.")
    if manifest.get("upstream_commit") != UPSTREAM_COMMIT:
        errors.append("Unexpected upstream commit.")
    if manifest.get("upstream_version") != UPSTREAM_VERSION:
        errors.append("Unexpected upstream version.")
    if manifest.get("license") != "MIT":
        errors.append("The upstream MIT license must be preserved.")
    patches = manifest.get("allowed_patches")
    if not isinstance(patches, dict) or set(patches) != PATCHED_FILES:
        errors.append("Unexpected engine patch list.")
    if manifest.get("excluded_paths") != [".github/"]:
        errors.append("Unexpected upstream exclusions.")
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        return errors + ["The manifest must contain upstream files."]
    integrations = manifest.get("integration_files")
    if not isinstance(integrations, list):
        return errors + ["The manifest must contain original integration files."]
    expected_paths: set[str] = set()
    actual_patches: set[str] = set()
    actual_integrations: set[str] = set()
    records = [(entry, False) for entry in entries] + [(entry, True) for entry in integrations]
    for entry, is_integration in records:
        if not isinstance(entry, dict):
            errors.append("Invalid manifest file entry.")
            continue
        relative = entry.get("path")
        if (
            not isinstance(relative, str)
            or not relative
            or PurePosixPath(relative).is_absolute()
            or ".." in PurePosixPath(relative).parts
            or "\\" in relative
            or str(PurePosixPath(relative)) != relative
        ):
            errors.append("Unsafe manifest file path.")
            continue
        if relative in expected_paths:
            errors.append(f"Duplicate manifest entry: {relative}")
        expected_paths.add(relative)
        if is_integration:
            actual_integrations.add(relative)
            if relative not in INTEGRATION_FILES:
                errors.append(f"Unauthorized original integration file: {relative}")
            if entry.get("license") != "GPL-3.0-or-later":
                errors.append(f"The original integration license must be preserved: {relative}")
            if "upstream_sha256" in entry or "vendored_sha256" in entry:
                errors.append(f"Original integration cannot claim upstream provenance: {relative}")
            original_hash = vendored_hash = entry.get("sha256")
        else:
            original_hash = entry.get("upstream_sha256")
            vendored_hash = entry.get("vendored_sha256")
            if relative in INTEGRATION_FILES:
                errors.append(f"Original integration must not be listed as upstream: {relative}")
        if not all(
            isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
            for value in (original_hash, vendored_hash)
        ):
            errors.append(f"Invalid SHA256 digest: {relative}")
            continue
        if original_hash != vendored_hash:
            actual_patches.add(relative)
            if relative not in PATCHED_FILES:
                errors.append(f"Unauthorized engine patch: {relative}")
        target = vendor_root / relative
        if target.is_symlink() or any(
            parent.is_symlink()
            for parent in target.parents
            if parent != vendor_root and vendor_root in parent.parents
        ):
            errors.append(f"Symlinks are not allowed in vendored source: {relative}")
            continue
        try:
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
        except OSError:
            errors.append(f"Missing or unreadable vendored file: {relative}")
            continue
        if digest != vendored_hash:
            errors.append(f"Vendored file hash mismatch: {relative}")
    if actual_patches != PATCHED_FILES:
        errors.append("The expected integration patches are missing or changed.")
    if actual_integrations != INTEGRATION_FILES:
        errors.append("The expected original integration files are missing or changed.")
    actual_paths = {
        path.relative_to(vendor_root).as_posix()
        for path in vendor_root.rglob("*")
        if (path.is_file() or path.is_symlink())
        and not IGNORED_CACHE_DIRECTORIES.intersection(
            path.relative_to(vendor_root).parts
        )
    }
    for relative in sorted(actual_paths - expected_paths):
        errors.append(f"Untracked vendored file: {relative}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-root", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    errors = verify_vendor(args.vendor_root, args.manifest)
    if errors:
        for error in errors:
            print(error)
        return 1
    print(f"Vendored downloader {UPSTREAM_VERSION} integrity verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Own, isolate and retire disposable macOS application verification trees."""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

OWNER = ".test-app-workspace.json"
INCOMPLETE = ".test-app-cleanup-incomplete.json"
LSREGISTER = (
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
DEFAULT_PARENT = Path(__file__).resolve().parents[1] / "build/ReleaseVerification.noindex"
REGISTRY_QUERY = """
import AppKit
import Foundation
var paths: [String] = []
for identifier in CommandLine.arguments.dropFirst() {
    paths += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier).map { $0.path }
}
let data = try JSONSerialization.data(withJSONObject: paths)
print(String(decoding: data, as: UTF8.self))
"""


class CleanupError(RuntimeError):
    """Cleanup was not safe or complete; keep the owned workspace for inspection."""


def _identity(path):
    details = path.lstat()
    if path.is_symlink() or not path.is_dir():
        raise CleanupError("The owned workspace is no longer a real directory.")
    return [details.st_dev, details.st_ino]


def _owner(root):
    root = Path(os.path.abspath(root))
    if root != root.resolve(strict=True):
        raise CleanupError("Refusing a symlinked test application path.")
    for parent in (root, *root.parents):
        marker = parent / OWNER
        if not parent.name.endswith(".noindex") or not marker.is_file():
            continue
        if marker.is_symlink():
            raise CleanupError("Refusing a symlinked workspace marker.")
        info = json.loads(marker.read_text())
        if info.get("identity") != _identity(parent) or info.get("format") != 1:
            raise CleanupError("The workspace ownership marker is invalid.")
        return parent
    raise CleanupError("Only an owned test workspace may be unregistered.")


def _record_failure(owner, reason, *, expected_identity=None):
    # Keep only fixed cleanup descriptions, not subprocess output or user data.
    if _owner(owner) != owner or (expected_identity is not None and _identity(owner) != expected_identity):
        raise CleanupError("Workspace ownership changed; refusing to write cleanup state.")
    target = owner / INCOMPLETE
    if target.is_symlink():
        raise CleanupError("Refusing a symlinked cleanup report.")
    if not target.exists():
        target.write_text(json.dumps({"status": "needs_attention", "reason": reason}) + "\n")


def _applications(root, *, reject_mounts=False):
    applications = []
    device = root.stat().st_dev
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        current = Path(directory)
        if reject_mounts and (os.path.ismount(current) or current.stat().st_dev != device):
            raise CleanupError("A mounted test volume remains; refusing recursive cleanup.")
        if reject_mounts and current != root and (OWNER in files or INCOMPLETE in files):
            raise CleanupError("A nested workspace still needs its own cleanup; preserving its parent.")
        subdirectories[:] = [name for name in subdirectories if not (current / name).is_symlink()]
        if current.suffix == ".app":
            applications.append(current)
    return sorted(applications, key=lambda path: len(path.parts), reverse=True)


def unregister_test_apps(root):
    """Unregister exact bundle paths beneath a marked workspace, never global state."""
    root = Path(root)
    owner = _owner(root)
    owner_identity = _identity(owner)
    if sys.platform != "darwin":
        return
    errors = []
    applications = _applications(root)
    identifiers = set()
    for application in applications:
        try:
            info_path = application / "Contents/Info.plist"
            if info_path.is_file():
                if not info_path.resolve().is_relative_to(application):
                    raise CleanupError("Test application metadata escapes its bundle.")
                info = plistlib.loads(info_path.read_bytes())
                if not isinstance(info, dict):
                    raise ValueError("Invalid test application metadata.")
                identifier = info.get("CFBundleIdentifier")
                if isinstance(identifier, str) and identifier:
                    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}", identifier):
                        raise ValueError("Invalid test application identifier.")
                    identifiers.add(identifier)
            subprocess.run(
                [LSREGISTER, "-u", str(application)], check=True, capture_output=True, timeout=30
            )
        except subprocess.CalledProcessError as error:
            # Apple's kLSApplicationNotFoundErr means no registration matches.
            # Accept only the exact path/code response, never arbitrary failures.
            missing = f"failed to scan {application}: -10814\n from spotlight".encode()
            streams = [value.strip() for value in (error.stdout, error.stderr) if value]
            if error.returncode != 1 or streams != [missing]:
                errors.append(application.relative_to(owner).as_posix())
        except (OSError, ValueError, CleanupError, subprocess.SubprocessError):
            errors.append(application.relative_to(owner).as_posix())
    if identifiers:
        try:
            registered = _registered_paths(identifiers)
            if any(str(application) in registered for application in applications):
                errors.append("registration-remains")
        except (OSError, ValueError, subprocess.SubprocessError):
            errors.append("registry-verification-failed")
    if errors:
        _record_failure(owner, "One or more test bundle registrations could not be removed.",
                        expected_identity=owner_identity)
        raise CleanupError("Test application unregistration failed; workspace preserved.")


def _registered_paths(identifiers):
    # Query only the fixture's bundle IDs, not the full application database.
    result = subprocess.run(
        ["/usr/bin/xcrun", "swift", "-e", REGISTRY_QUERY, *sorted(identifiers)],
        check=True, capture_output=True, timeout=60,
    )
    paths = json.loads(result.stdout)
    if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
        raise ValueError("Unexpected scoped LaunchServices response.")
    return set(paths)


def _running_below(root):
    if sys.platform != "darwin":
        return False
    result = subprocess.run(
        ["/bin/ps", "-axo", "comm="], check=True, capture_output=True, text=True, timeout=15
    )
    prefix = str(root) + os.sep
    return any(line.strip().startswith(prefix) for line in result.stdout.splitlines())


class TestAppWorkspace:
    """TemporaryDirectory-like owner with no unsafe implicit destructor cleanup.

    Keep archives, reports and trusted metadata outside this disposable tree.
    A live process, mounted volume, ownership change or unregister failure blocks
    removal. Callers must normally detach their own volumes before leaving.
    """

    def __init__(self, *, prefix="verification-", dir=None):
        if not prefix or Path(prefix).name != prefix:
            raise ValueError("Workspace prefix must be a nonempty filename prefix.")
        parent = Path(dir) if dir is not None else DEFAULT_PARENT
        parent.mkdir(parents=True, exist_ok=True)
        parent = parent.resolve(strict=True)
        self.name = tempfile.mkdtemp(prefix=prefix, suffix=".noindex", dir=parent)
        self.path = Path(self.name)
        self.identity = _identity(self.path)
        self.token = uuid.uuid4().hex
        self.cleaned = False
        (self.path / OWNER).write_text(json.dumps({
            "format": 1, "identity": self.identity, "token": self.token,
        }) + "\n")

    def __enter__(self):
        return self.name

    def _assert_owned(self):
        if self.path != self.path.resolve(strict=True) or _identity(self.path) != self.identity:
            raise CleanupError("Workspace ownership changed; refusing cleanup.")
        marker = self.path / OWNER
        if marker.is_symlink():
            raise CleanupError("Workspace marker changed; refusing cleanup.")
        info = json.loads(marker.read_text())
        if info != {"format": 1, "identity": self.identity, "token": self.token}:
            raise CleanupError("Workspace marker changed; refusing cleanup.")

    def cleanup(self):
        if self.cleaned:
            return
        self._assert_owned()
        if os.path.lexists(self.path / INCOMPLETE):
            raise CleanupError("Earlier cleanup failed; retained workspace needs attention.")
        try:
            # Never descend into mounted volumes or remove executing binaries.
            _applications(self.path, reject_mounts=True)
            running = _running_below(self.path)
            unregister_test_apps(self.path)
            if running:
                raise CleanupError("A test application is still running; workspace preserved.")
            # This is exclusively a new random directory owned by this instance.
            # It never includes the caller's app, release archives or user state.
            self._assert_owned()
            if os.path.lexists(self.path / INCOMPLETE):
                raise CleanupError("Cleanup state changed; refusing removal.")
            _applications(self.path, reject_mounts=True)
            if _running_below(self.path):
                raise CleanupError("A test application is now running; workspace preserved.")
            shutil.rmtree(self.path)
        except (OSError, subprocess.SubprocessError, CleanupError):
            try:
                self._assert_owned()
            except (OSError, ValueError, CleanupError):
                pass
            else:
                _record_failure(self.path, "Workspace cleanup did not complete safely.",
                                expected_identity=self.identity)
            raise
        self.cleaned = True

    def __exit__(self, kind, exception, traceback):
        try:
            self.cleanup()
        except BaseException as cleanup_error:
            if exception is not None:
                raise BaseExceptionGroup(
                    "Verification and workspace cleanup both failed.", [exception, cleanup_error]
                ) from None
            raise
        return False

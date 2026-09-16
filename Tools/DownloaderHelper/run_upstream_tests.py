#!/usr/bin/env python3
"""Run preserved downloader tests offline from an isolated temporary source copy."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from verify_vendor import HELPER_ROOT, verify_vendor

OFFLINE_TEST_BOOTSTRAP = r'''
import ipaddress
import socket
import sys


def local_host(host):
    if isinstance(host, bytes):
        host = host.decode("ascii", errors="replace")
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except (TypeError, ValueError):
        return False


def require_local(address):
    if not isinstance(address, tuple) or not local_host(address[0]):
        raise OSError("External network is blocked during offline engine tests")


original_connect = socket.socket.connect
original_connect_ex = socket.socket.connect_ex
original_sendto = socket.socket.sendto
original_getaddrinfo = socket.getaddrinfo


def guarded_connect(self, address):
    if self.family in (socket.AF_INET, socket.AF_INET6):
        require_local(address)
    return original_connect(self, address)


def guarded_connect_ex(self, address):
    if self.family in (socket.AF_INET, socket.AF_INET6):
        require_local(address)
    return original_connect_ex(self, address)


def guarded_sendto(self, data, *arguments):
    if self.family in (socket.AF_INET, socket.AF_INET6) and arguments:
        require_local(arguments[-1])
    return original_sendto(self, data, *arguments)


def guarded_getaddrinfo(host, port, *arguments, **keywords):
    if host is not None and not local_host(host):
        raise OSError("External DNS is blocked during offline engine tests")
    return original_getaddrinfo(host, port, *arguments, **keywords)


socket.socket.connect = guarded_connect
socket.socket.connect_ex = guarded_connect_ex
socket.socket.sendto = guarded_sendto
socket.getaddrinfo = guarded_getaddrinfo

import pytest
raise SystemExit(pytest.main(["-p", "no:cacheprovider", "tests", *sys.argv[1:]]))
'''


def isolated_environment(environment: dict[str, str]) -> dict[str, str]:
    """Exclude host runtime paths and preloaded plugins without changing HOME."""
    result = {
        key: value
        for key, value in environment.items()
        if not key.startswith(("CHENGYING_", "OMD_"))
        and key not in {"PYTHONPATH", "PYTHONHOME", "PYTEST_ADDOPTS", "PYTEST_PLUGINS"}
    }
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    result["PYTHONUNBUFFERED"] = "1"
    result["PYTEST_DISABLE_PLUGIN_AUTOLOAD"] = "1"
    result["NO_PROXY"] = "127.0.0.1,localhost,::1"
    result["no_proxy"] = result["NO_PROXY"]
    return result


def copy_manifested_source(destination: Path) -> None:
    """Copy only verified tracked files, never user state or runtime caches."""
    manifest = json.loads((HELPER_ROOT / "upstream-manifest.json").read_text(encoding="utf-8"))
    vendor = HELPER_ROOT / "vendor" / "rednote"
    for entry in manifest["files"]:
        relative = entry["path"]
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(vendor / relative, target, follow_symlinks=False)


def main(arguments: list[str] | None = None) -> int:
    errors = verify_vendor()
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    if arguments and arguments[0] == "--":
        arguments.pop(0)
    with tempfile.TemporaryDirectory(prefix="chengying-downloader-tests-") as directory:
        isolated_source = Path(directory) / "engine"
        copy_manifested_source(isolated_source)
        errors = verify_vendor(isolated_source)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("Running offline downloader tests from a verified temporary source copy.", flush=True)
        result = subprocess.run(
            [sys.executable, "-B", "-c", OFFLINE_TEST_BOOTSTRAP, *arguments],
            cwd=isolated_source,
            env=isolated_environment(os.environ),
            check=False,
        )
        print(f"Offline downloader test exit code: {result.returncode}", flush=True)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

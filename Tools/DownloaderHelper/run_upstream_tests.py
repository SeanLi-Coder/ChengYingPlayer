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

OFFLINE_GUARD_ENV = "CHENGYING_OFFLINE_TEST_GUARD_PATH"

NETWORK_GUARD_SOURCE = r'''
import ipaddress
import os
import socket
import subprocess


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
original_popen = subprocess.Popen


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
    if host in ("localhost", b"localhost"):
        family = arguments[0] if arguments else keywords.get("family", 0)
        host = "::1" if family == socket.AF_INET6 else "127.0.0.1"
    return original_getaddrinfo(host, port, *arguments, **keywords)


def guarded_gethostbyaddr(host):
    if not local_host(host):
        raise OSError("External DNS is blocked during offline engine tests")
    address = host.decode("ascii") if isinstance(host, bytes) else host
    if address == "localhost":
        address = "127.0.0.1"
    return ("localhost", [], [address])


def guarded_getfqdn(host=""):
    if not local_host(host):
        raise OSError("External DNS is blocked during offline engine tests")
    return "localhost"


def guarded_gethostbyname(host):
    if not local_host(host):
        raise OSError("External DNS is blocked during offline engine tests")
    address = host.decode("ascii") if isinstance(host, bytes) else host
    if address == "localhost":
        return "127.0.0.1"
    if ipaddress.ip_address(address).version != 4:
        raise socket.gaierror("IPv4 address required")
    return address


def guarded_gethostbyname_ex(host):
    return ("localhost", [], [guarded_gethostbyname(host)])


class OfflinePopen(original_popen):
    def __init__(self, *arguments, **keywords):
        guard_path = os.environ.get("CHENGYING_OFFLINE_TEST_GUARD_PATH")
        if guard_path:
            # Some lifecycle fixtures replace PYTHONPATH with package locations.
            # Keep their package paths while propagating this opt-in guard to
            # real launcher, venv, and process-guardian Python subprocesses.
            positional = list(arguments)
            environment = positional[10] if len(positional) > 10 else keywords.get("env")
            environment = dict(os.environ if environment is None else environment)
            paths = [path for path in environment.get("PYTHONPATH", "").split(os.pathsep)
                     if path and path != guard_path]
            environment["PYTHONPATH"] = os.pathsep.join([guard_path, *paths])
            environment["CHENGYING_OFFLINE_TEST_GUARD_PATH"] = guard_path
            if len(positional) > 10:
                positional[10] = environment
            else:
                keywords["env"] = environment
            arguments = tuple(positional)
        super().__init__(*arguments, **keywords)


socket.socket.connect = guarded_connect
socket.socket.connect_ex = guarded_connect_ex
socket.socket.sendto = guarded_sendto
socket.getaddrinfo = guarded_getaddrinfo
socket.gethostbyaddr = guarded_gethostbyaddr
socket.getfqdn = guarded_getfqdn
socket.gethostbyname = guarded_gethostbyname
socket.gethostbyname_ex = guarded_gethostbyname_ex
subprocess.Popen = OfflinePopen
socket._chengying_offline_guard = True
'''

OFFLINE_TEST_BOOTSTRAP = (
    "import socket\nimport sys\n"
    "if not getattr(socket, '_chengying_offline_guard', False):\n"
    f"    exec({NETWORK_GUARD_SOURCE!r})\n"
    + '''

import pytest
raise SystemExit(pytest.main(["-p", "no:cacheprovider", "tests", *sys.argv[1:]]))
'''
)


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


def create_offline_guard(destination: Path) -> None:
    """Create an opt-in child-process guard outside the preserved source tree."""
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "sitecustomize.py").write_text(NETWORK_GUARD_SOURCE, encoding="utf-8")


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
        guard = Path(directory) / "offline-guard"
        create_offline_guard(guard)
        environment = isolated_environment(os.environ)
        environment[OFFLINE_GUARD_ENV] = str(guard)
        environment["PYTHONPATH"] = str(guard)
        result = subprocess.run(
            [sys.executable, "-B", "-c", OFFLINE_TEST_BOOTSTRAP, *arguments],
            cwd=isolated_source,
            env=environment,
            check=False,
        )
        print(f"Offline downloader test exit code: {result.returncode}", flush=True)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HELPER_ROOT))
SPEC = importlib.util.spec_from_file_location("downloader_upstream_runner", HELPER_ROOT / "run_upstream_tests.py")
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class UpstreamRunnerTests(unittest.TestCase):
    def test_host_runtime_paths_and_plugins_are_not_inherited(self):
        original = {
            "HOME": "/example/home", "PATH": "/usr/bin:/bin",
            "CHENGYING_DOWNLOAD_DATA_DIR": "/private/state",
            "CHENGYING_DOWNLOAD_DEFAULT_DIR": "/private/downloads",
            "CHENGYING_OTHER_SETTING": "private",
            "OMD_RUNTIME_DIR": "/private/runtime", "OMD_STOP_TOKEN": "private",
            "PYTHONPATH": "/private/imports", "PYTHONHOME": "/private/python",
            "PYTEST_ADDOPTS": "--unexpected", "PYTEST_PLUGINS": "unexpected",
        }
        environment = RUNNER.isolated_environment(original)
        self.assertEqual(environment["HOME"], original["HOME"])
        self.assertEqual(environment["PATH"], original["PATH"])
        self.assertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        self.assertEqual(environment["PYTEST_DISABLE_PLUGIN_AUTOLOAD"], "1")
        self.assertNotIn("PYTHONPATH", environment)
        self.assertNotIn("PYTHONHOME", environment)
        self.assertNotIn("PYTEST_ADDOPTS", environment)
        self.assertNotIn("PYTEST_PLUGINS", environment)
        self.assertFalse(any(key.startswith(("CHENGYING_", "OMD_")) for key in environment))
        self.assertIn("CHENGYING_DOWNLOAD_DATA_DIR", original)

    def test_copy_contains_only_manifested_source(self):
        with tempfile.TemporaryDirectory(prefix="chengying-runner-copy-") as name:
            destination = Path(name) / "engine"
            RUNNER.copy_manifested_source(destination)
            self.assertEqual(RUNNER.verify_vendor(destination), [])
            self.assertFalse((destination / "data").exists())
            self.assertFalse((destination / "downloads").exists())
            self.assertFalse((destination / ".venv").exists())
            self.assertFalse((destination / ".git").exists())

    def test_offline_bootstrap_blocks_external_tcp_udp_and_dns(self):
        bootstrap = RUNNER.OFFLINE_TEST_BOOTSTRAP.split("\nimport pytest\n", 1)[0]
        probe = r'''
checks = 0
for operation in (
    lambda: socket.socket().connect(("192.0.2.1", 443)),
    lambda: socket.socket().connect_ex(("192.0.2.1", 443)),
    lambda: socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("192.0.2.1", 53)),
    lambda: socket.getaddrinfo("example.invalid", 443),
    lambda: socket.gethostbyaddr("192.0.2.1"),
    lambda: socket.getfqdn("192.0.2.1"),
    lambda: socket.gethostbyname("example.invalid"),
    lambda: socket.gethostbyname_ex("example.invalid"),
):
    try:
        operation()
    except OSError as error:
        assert "blocked during offline engine tests" in str(error)
        checks += 1
    else:
        raise AssertionError("External network was not blocked")
assert checks == 8
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
client = socket.socket()
client.connect(listener.getsockname())
connection, address = listener.accept()
connection.close()
client.close()
listener.close()
assert socket.getaddrinfo("localhost", 80)
print("Offline network guards verified.")
'''
        result = subprocess.run(
            [sys.executable, "-B", "-c", bootstrap + probe],
            capture_output=True, text=True, check=True, timeout=10,
            env=RUNNER.isolated_environment(os.environ),
        )
        self.assertEqual(result.stdout.strip(), "Offline network guards verified.")

    def test_loopback_http_server_never_uses_the_system_reverse_resolver(self):
        bootstrap = RUNNER.OFFLINE_TEST_BOOTSTRAP.split("\nimport pytest\n", 1)[0]
        before_guard = r'''
import socket
def unexpected_reverse_lookup(*arguments):
    raise AssertionError("The system reverse resolver must not be called")
socket.gethostbyaddr = unexpected_reverse_lookup
'''
        probe = r'''
from http.server import BaseHTTPRequestHandler, HTTPServer
with HTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
    assert server.server_name == "localhost"
assert socket.gethostbyaddr("::1") == ("localhost", [], ["::1"])
assert socket.getfqdn("127.0.0.1") == "localhost"
print("Loopback reverse DNS isolation verified.")
'''
        result = subprocess.run(
            [sys.executable, "-B", "-c", before_guard + bootstrap + probe],
            capture_output=True, text=True, check=True, timeout=10,
            env=RUNNER.isolated_environment(os.environ),
        )
        self.assertEqual(result.stdout.strip(), "Loopback reverse DNS isolation verified.")

    def test_child_and_grandchild_keep_guard_when_fixtures_replace_pythonpath(self):
        probe = r'''
import os
import socket
import subprocess
import sys
from pathlib import Path
assert getattr(socket, "_chengying_offline_guard", False)
assert socket.getfqdn("127.0.0.1") == "localhost"
try:
    socket.gethostbyaddr("192.0.2.1")
except OSError:
    pass
else:
    raise AssertionError("External reverse DNS was not blocked")
depth = int(sys.argv[1])
if depth < 2:
    import fixture_dependency
    assert fixture_dependency.VALUE == "fixture dependency preserved"
    assert Path(fixture_dependency.__file__).resolve() == Path(sys.argv[2], "fixture_dependency.py").resolve()
if depth:
    environment = {"PATH": os.environ.get("PATH", ""), "PYTHONPATH": sys.argv[2]}
    child = subprocess.run(
        [getattr(sys, "_base_executable", sys.executable), "-B", "-c", sys.argv[3], str(depth-1), sys.argv[2], sys.argv[3]],
        env=environment, capture_output=True, text=True, check=True, timeout=5,
    )
    assert child.stdout.strip() == "Guard inherited."
else:
    from http.server import BaseHTTPRequestHandler, HTTPServer
    with HTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler) as server:
        assert server.server_name == "localhost"
print("Guard inherited.")
'''
        with tempfile.TemporaryDirectory(prefix="chengying-child-guard-") as name:
            directory = Path(name)
            guard = directory / "guard"
            packages = directory / "fixture-package-path"
            packages.mkdir()
            (packages / "fixture_dependency.py").write_text(
                'VALUE = "fixture dependency preserved"\n', encoding="utf-8",
            )
            RUNNER.create_offline_guard(guard)
            environment = RUNNER.isolated_environment(os.environ)
            environment[RUNNER.OFFLINE_GUARD_ENV] = str(guard)
            environment["PYTHONPATH"] = str(guard)
            result = subprocess.run(
                [sys.executable, "-B", "-c", probe, "2", str(packages), probe],
                capture_output=True, text=True, check=True, timeout=15,
                env=environment,
            )
            self.assertEqual(result.stdout.strip(), "Guard inherited.")

    def test_positional_popen_environment_is_preserved_without_mutating_callers(self):
        probe = r'''
import os
import subprocess
import sys
assert getattr(__import__("socket"), "_chengying_offline_guard", False)
environment = {
    "PATH": os.environ.get("PATH", ""),
    "PYTHONPATH": sys.argv[1],
    "FIXTURE_MARKER": "explicit environment preserved",
}
original = environment.copy()
parent_environment = dict(os.environ)
child_probe = """
import os
import socket
import sys
from pathlib import Path
import fixture_dependency
assert getattr(socket, "_chengying_offline_guard", False)
assert socket.getfqdn("127.0.0.1") == "localhost"
assert fixture_dependency.VALUE == "positional dependency preserved"
assert Path(fixture_dependency.__file__).resolve() == Path(sys.argv[1], "fixture_dependency.py").resolve()
assert os.environ["PYTHONPATH"].split(os.pathsep) == [sys.argv[2], sys.argv[1]]
assert os.environ["CHENGYING_OFFLINE_TEST_GUARD_PATH"] == sys.argv[2]
assert os.environ["FIXTURE_MARKER"] == "explicit environment preserved"
assert "OFFLINE_PARENT_SENTINEL" not in os.environ
print("Positional environment preserved.")
"""
command = [getattr(sys, "_base_executable", sys.executable), "-B", "-c", child_probe, sys.argv[1], sys.argv[2]]
# The eleventh positional argument is env in the real Popen signature.
with subprocess.Popen(command, -1, None, None, subprocess.PIPE, subprocess.PIPE,
                      None, True, False, None, environment, text=True) as child:
    stdout, stderr = child.communicate(timeout=5)
    assert child.returncode == 0, stderr
assert stdout.strip() == "Positional environment preserved."
assert environment == original
assert dict(os.environ) == parent_environment
print("Positional environment preserved.")
'''
        with tempfile.TemporaryDirectory(prefix="chengying-positional-guard-") as name:
            directory = Path(name)
            guard = directory / "guard"
            packages = directory / "fixture-package-path"
            packages.mkdir()
            (packages / "fixture_dependency.py").write_text(
                'VALUE = "positional dependency preserved"\n', encoding="utf-8",
            )
            RUNNER.create_offline_guard(guard)
            environment = RUNNER.isolated_environment(os.environ)
            environment[RUNNER.OFFLINE_GUARD_ENV] = str(guard)
            environment["PYTHONPATH"] = str(guard)
            environment["OFFLINE_PARENT_SENTINEL"] = "not inherited by an explicit environment"
            result = subprocess.run(
                [sys.executable, "-B", "-c", probe, str(packages), str(guard)],
                capture_output=True, text=True, check=True, timeout=10,
                env=environment,
            )
            self.assertEqual(result.stdout.strip(), "Positional environment preserved.")


if __name__ == "__main__":
    unittest.main()

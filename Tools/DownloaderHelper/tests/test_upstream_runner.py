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
):
    try:
        operation()
    except OSError as error:
        assert "blocked during offline engine tests" in str(error)
        checks += 1
    else:
        raise AssertionError("External network was not blocked")
assert checks == 4
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


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import io
import subprocess
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from helper import (
    MAX_COMMAND_BYTES,
    ShutdownController,
    parse_arguments,
    validate_paths,
)
from smoke_helper import read_event


@pytest.mark.parametrize(
    "data",
    [
        b"",
        b'{"command":"shutdown"}\n',
        b"invalid\n",
        b"[]\n",
        b"x" * (MAX_COMMAND_BYTES + 2),
        b'{"command":"unknown"}\n',
    ],
)
def test_parent_eof_or_invalid_protocol_requests_shutdown(data):
    controller = ShutdownController(emit=lambda _: None, own_process_group=False)
    controller.finished.set()
    controller.read_commands(io.BytesIO(data))
    assert controller.requested.is_set()


def test_ping_does_not_echo_untrusted_input():
    events = []
    controller = ShutdownController(emit=events.append, own_process_group=False)
    controller.finished.set()
    controller.read_commands(io.BytesIO(b'{"command":"ping","id":"private-value"}\n'))
    assert events == [{"type": "pong", "protocol_version": 1}]


def test_smoke_reader_times_out_on_partial_lines():
    with subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import sys,time; sys.stdout.write('{'); sys.stdout.flush(); time.sleep(5)",
        ],
        stdout=subprocess.PIPE,
    ) as child:
        started = time.monotonic()
        try:
            with pytest.raises(AssertionError, match="in time"):
                read_event(child, timeout=0.2)
            assert time.monotonic() - started < 2
        finally:
            child.terminate()
            child.wait(timeout=5)


def test_smoke_reader_preserves_coalesced_messages():
    with subprocess.Popen(
        [sys.executable, "-c", 'print(\'{"type":"one"}\\n{"type":"two"}\')'],
        stdout=subprocess.PIPE,
    ) as child:
        assert read_event(child)["type"] == "one"
        assert read_event(child)["type"] == "two"
        assert child.wait(timeout=5) == 0


def test_directory_must_not_be_home_or_bundle(tmp_path):
    executable = tmp_path / "ffmpeg"
    executable.touch()
    executable.chmod(0o755)
    for directory in (
        str(Path.home()),
        str(Path(__file__).resolve().parents[1]),
        "/",
        "relative",
    ):
        arguments = parse_arguments(
            [
                "--stdio",
                "--data-dir",
                directory,
                "--download-dir",
                str(tmp_path / "downloads"),
                "--ffmpeg",
                str(executable),
                "--ffprobe",
                str(executable),
            ]
        )
        with pytest.raises(ValueError):
            validate_paths(arguments)

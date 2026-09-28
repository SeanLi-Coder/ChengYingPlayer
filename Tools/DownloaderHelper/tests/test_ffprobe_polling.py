"""Real-process FFprobe polling regressions using only synthetic input."""

from __future__ import annotations

import hashlib
import io
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest
from yt_dlp.utils import DownloadCancelled

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader
from app.downloader import DownloaderConfig, MediaDownloader
from app.errors import MediaDownloadError

PAYLOAD = bytes(range(256)) * 8192


@pytest.fixture
def engine():
    return MediaDownloader(DownloaderConfig(cookie_browser=None))


@pytest.fixture
def processes(monkeypatch):
    original = subprocess.Popen
    created = []

    class ObservedProcess(original):
        def __init__(self, *args, **kwargs):
            self.stdin_source = kwargs.get("stdin")
            self.poll_timeouts = 0
            super().__init__(*args, **kwargs)
            created.append(self)

        def communicate(self, *args, **kwargs):
            try:
                return super().communicate(*args, **kwargs)
            except subprocess.TimeoutExpired:
                self.poll_timeouts += 1
                raise

    monkeypatch.setattr(downloader.subprocess, "Popen", ObservedProcess)
    yield created
    for process in created:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=3)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def command(source):
    return [sys.executable, "-c", source]


def assert_resources_closed(process):
    assert process.poll() is not None
    assert process.stdout.closed
    if hasattr(process.stdin_source, "closed"):
        assert process.stdin_source.closed


def test_delayed_reader_receives_all_input_after_first_poll_timeout(engine, processes):
    result = engine._run_ffprobe(
        command(
            "import hashlib,sys,time; time.sleep(0.25); "
            "data=sys.stdin.buffer.read(); "
            "sys.stdout.write(hashlib.sha256(data).hexdigest())"
        ),
        input_data=PAYLOAD,
        timeout_seconds=3,
        should_cancel=lambda: False,
    )

    assert result == hashlib.sha256(PAYLOAD).hexdigest().encode("ascii")
    assert processes[0].poll_timeouts >= 1
    assert processes[0].returncode == 0
    assert_resources_closed(processes[0])


@pytest.mark.parametrize("input_data", [None, b""])
def test_no_input_and_empty_input_deliver_eof_after_poll_timeout(
    engine, processes, input_data
):
    result = engine._run_ffprobe(
        command(
            "import sys,time; time.sleep(0.25); "
            "sys.stdout.write(str(len(sys.stdin.buffer.read())))"
        ),
        input_data=input_data,
        timeout_seconds=3,
        should_cancel=lambda: False,
    )

    assert result == b"0"
    assert processes[0].poll_timeouts >= 1
    if input_data is None:
        assert processes[0].stdin_source == subprocess.DEVNULL
    assert_resources_closed(processes[0])


@pytest.mark.parametrize("input_data", [None, PAYLOAD], ids=["no-input", "large-input"])
def test_cancellation_stops_delayed_child_and_closes_resources(
    engine, processes, input_data
):
    checks = 0

    def should_cancel():
        nonlocal checks
        checks += 1
        return checks >= 3

    started = time.monotonic()
    with pytest.raises(DownloadCancelled, match="Task cancelled"):
        engine._run_ffprobe(
            command("import time; time.sleep(10)"),
            input_data=input_data,
            timeout_seconds=5,
            should_cancel=should_cancel,
        )

    assert time.monotonic() - started < 2
    assert checks == 3
    assert processes[0].poll_timeouts >= 1
    assert_resources_closed(processes[0])


@pytest.mark.parametrize("input_data", [None, PAYLOAD], ids=["no-input", "large-input"])
def test_deadline_is_not_reset_by_poll_timeouts(engine, processes, input_data):
    started = time.monotonic()
    with pytest.raises(TimeoutError, match="FFprobe timed out"):
        engine._run_ffprobe(
            command("import time; time.sleep(10)"),
            input_data=input_data,
            timeout_seconds=0.35,
            should_cancel=lambda: False,
        )

    elapsed = time.monotonic() - started
    assert 0.3 <= elapsed < 2
    assert processes[0].poll_timeouts >= 1
    assert_resources_closed(processes[0])


def test_callback_control_signal_reaps_child(engine, processes):
    checks = 0

    def should_cancel():
        nonlocal checks
        checks += 1
        if checks >= 2:
            raise KeyboardInterrupt("Synthetic control signal")
        return False

    with pytest.raises(KeyboardInterrupt, match="Synthetic control signal"):
        engine._run_ffprobe(
            command("import time; time.sleep(10)"),
            input_data=PAYLOAD,
            timeout_seconds=3,
            should_cancel=should_cancel,
        )

    assert_resources_closed(processes[0])


def test_start_failure_closes_input_source(engine, monkeypatch):
    sources = []

    def fail_to_start(*args, **kwargs):
        sources.append(kwargs["stdin"])
        raise OSError("Synthetic process start failure")

    monkeypatch.setattr(downloader.subprocess, "Popen", fail_to_start)
    with pytest.raises(MediaDownloadError, match="could not be started"):
        engine._run_ffprobe(
            command("pass"),
            input_data=PAYLOAD,
            timeout_seconds=3,
            should_cancel=lambda: False,
        )

    assert len(sources) == 1
    assert sources[0].closed


@pytest.mark.parametrize("failure_stage", ["create", "write", "seek"])
def test_input_file_failure_is_fixed_and_closes_resources(
    engine, monkeypatch, failure_stage
):
    sources = []
    raw_error = "Synthetic private temporary path must not escape"

    class FailedInput(io.BytesIO):
        def write(self, data):
            if failure_stage == "write":
                raise OSError(raw_error)
            return super().write(data)

        def seek(self, *args):
            if failure_stage == "seek":
                raise OSError(raw_error)
            return super().seek(*args)

    def input_file():
        if failure_stage == "create":
            raise OSError(raw_error)
        source = FailedInput()
        sources.append(source)
        return source

    def reject_process(*args, **kwargs):
        pytest.fail("Input preparation failure must not start a process")

    monkeypatch.setattr(downloader.tempfile, "TemporaryFile", input_file)
    monkeypatch.setattr(downloader.subprocess, "Popen", reject_process)
    with pytest.raises(MediaDownloadError) as caught:
        engine._run_ffprobe(
            command("pass"),
            input_data=PAYLOAD,
            timeout_seconds=3,
            should_cancel=lambda: False,
        )

    assert str(caught.value) == downloader.FFPROBE_START_MESSAGE
    assert raw_error not in str(caught.value)
    assert all(source.closed for source in sources)


def test_delayed_real_ffprobe_still_uses_pipe_protocol(
    engine, processes, monkeypatch, tmp_path
):
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = engine._find_ffprobe_executable()
    if not ffmpeg or not ffprobe:
        pytest.skip("FFmpeg and FFprobe are required for the synthetic media fixture")
    source = tmp_path / "fragmented.mp4"
    subprocess.run(
        [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            "testsrc2=size=640x360:rate=30", "-t", "12", "-an", "-c:v",
            "libx264", "-preset", "ultrafast", "-g", "30", "-movflags",
            "frag_keyframe+empty_moov+default_base_moof", str(source),
        ],
        check=True,
        capture_output=True,
        timeout=45,
    )
    payload = source.read_bytes()
    assert len(payload) > downloader.DOUYIN_PROBE_BYTES
    observed_popen = downloader.subprocess.Popen
    original_commands = []

    def delayed_popen(arguments, **kwargs):
        original_commands.append(arguments)
        return observed_popen(
            [
                sys.executable, "-c",
                (
                    "import os,sys,time; time.sleep(0.25); "
                    "os.execv(sys.argv[1], sys.argv[1:])"
                ),
                *arguments,
            ],
            **kwargs,
        )

    monkeypatch.setattr(downloader.subprocess, "Popen", delayed_popen)
    media = engine._ffprobe_douyin_media(
        payload[:downloader.DOUYIN_PROBE_BYTES], should_cancel=lambda: False
    )

    assert original_commands[0][-2:] == ["-i", "pipe:0"]
    assert media is not None
    assert (media["width"], media["height"]) == (640, 360)
    assert float(media["duration"]) == pytest.approx(1.0, abs=0.05)
    assert processes[-1].poll_timeouts >= 1
    assert_resources_closed(processes[-1])

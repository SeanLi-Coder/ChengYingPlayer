# ChengYing Video Tools Helper

This directory contains the non-AI media-processing helper used by the macOS app. It
exposes the tested media-preservation pipeline as a small, persistent JSON Lines service
suitable for launching with `Process` from Swift.

The helper supports:

- media probing;
- frame-accurate high-fidelity clipping;
- lossless still-frame extraction for ranges up to five seconds; and
- permanent clockwise rotation by 90, 180, 270, or 360 degrees.

All operations write to owned partial output, preserve the source file, choose a unique
destination name, validate the result, and publish only after verification. This helper
contains no AI, model download, proxy, Windows, or web-server code.

## Runtime design

`helper.py` and `media.py` use only the Python standard library. A release build freezes
them into a standalone Mach-O executable with PyInstaller, so an installed app does not
depend on a system Python installation. FFmpeg and FFprobe remain separate executables
and their absolute paths are always passed explicitly by the app.

The helper process is persistent but serial: one active media task is allowed at a
time. The app can cancel in-band or terminate the helper with `SIGTERM`. Graceful
cancellation stops FFmpeg, waits for it to exit, and removes partial output.

See [PROTOCOL.md](PROTOCOL.md) for the complete versioned protocol.

## Build

Use a dedicated Python 3.11-or-newer environment:

```bash
python3 -m pip install -r Tools/VideoToolsHelper/requirements-build.txt
HELPER_PYTHON=python3 Tools/VideoToolsHelper/build_helper.sh
```

The fixed output path is:

```text
deps/executable/chengying-video-tools-helper
```

The generated executable is intentionally ignored by Git. Set
`HELPER_TARGET_ARCH=arm64`, `x86_64`, or `universal2` when the selected Python
distribution supports that target. The app release pipeline is responsible for signing
the nested helper together with the rest of the app bundle. Release builds should set
`HELPER_CODESIGN_IDENTITY` and `HELPER_REQUIRE_SIGNING=1`; the script passes the identity
into PyInstaller so embedded Python libraries are signed, verifies the requested Mach-O
architecture and signature, runs a frozen ready/ping smoke test when the bundled FFmpeg
tools exist, and atomically publishes the verified executable.

## Test

Install the development requirements, then run the media and protocol suites:

```bash
python3 -m pip install -r Tools/VideoToolsHelper/requirements-dev.txt
cd Tools/VideoToolsHelper
python3 -m pytest -q
python3 -m ruff check helper.py media.py tests/test_media.py tests/test_protocol.py
```

The integration tests require FFmpeg and FFprobe on `PATH`. They create synthetic video
fixtures and verify clipping, image extraction, rotation, cancellation, cleanup,
metadata preservation, and protocol framing. The build script separately verifies the
frozen helper against bundled FFmpeg and FFprobe executables.

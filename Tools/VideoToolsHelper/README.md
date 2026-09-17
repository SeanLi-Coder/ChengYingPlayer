# ChengYing Video Tools Helper

This directory contains the non-AI media-processing helper used by the macOS app. It
exposes the tested media-preservation pipeline as a small, persistent JSON Lines service
suitable for launching with `Process` from Swift.

The helper supports:

- media probing;
- frame-accurate high-fidelity clipping;
- lossless still-frame extraction for ranges up to five seconds;
- permanent clockwise rotation by 90, 180, 270, or 360 degrees; and
- whole-video MP4 / MKV / MOV conversion, with lossless stream copy by default or
  explicit high-quality H.264 / HEVC video re-encoding.

All operations write to owned partial output, preserve the source file, choose a unique
destination name, validate the result, and publish only after verification. This helper
contains no AI, model download, proxy, Windows, or web-server code.

## Runtime design

`helper.py`, `media.py`, and `conversion.py` use only the Python standard library. A release build freezes
them into a standalone Mach-O executable with PyInstaller, so an installed app does not
depend on a system Python installation. FFmpeg and FFprobe remain separate executables
and their absolute paths are always passed explicitly by the app.

The helper process is persistent but serial: one active media task is allowed at a
time. The app can cancel in-band or terminate the helper with `SIGTERM`. Graceful
cancellation stops FFmpeg, waits for it to exit, and removes partial output.

See [PROTOCOL.md](PROTOCOL.md) for the complete versioned protocol.

## Build

Use the checksum-pinned CPython 3.13.2 build environment:

```bash
python3 -m pip install --require-hashes --only-binary=:all: -r Tools/VideoToolsHelper/requirements-build.txt
HELPER_PYTHON=python3 Tools/VideoToolsHelper/build_helper.sh
```

The fixed output path is:

```text
deps/executable/chengying-video-tools-helper
```

The generated executable is intentionally ignored by Git. Set
`HELPER_TARGET_ARCH=arm64`, `x86_64`, or `universal2` when the selected Python
distribution supports that target. The shared builder also builds the subtitle helper.
Both helpers always receive `runtime-entitlements.plist`, containing only
`com.apple.security.cs.disable-library-validation=true`. A frozen helper is a separate
process that loads its extracted Python library; it does not inherit the containing
application's entitlement. Without this per-process entitlement, an ad-hoc helper
re-signed with hardened runtime can pass signature verification but fail to load Python
on a Mac enforcing library validation.

Xcode's Copy Files signing preserves the helpers' embedded entitlements while enabling
hardened runtime. The build script checks the signed executable's entitlement before
running the frozen ready/ping smoke test and atomically publishing the helper. The final
application packaging step checks each helper again after Xcode signing. This narrowly
scoped application entitlement does not change SIP, Gatekeeper, or system settings.

The current public build uses ad-hoc signatures; it is not Developer ID signed or
notarized. A build with an available signing certificate can set
`HELPER_CODESIGN_IDENTITY` and `HELPER_REQUIRE_SIGNING=1`. The script passes that identity
to PyInstaller to sign the embedded Python libraries and retain hardened runtime signing,
but this setting alone does not perform notarization or certify distribution trust.

## Test

Install the development requirements, then run the media and protocol suites:

```bash
python3 -m pip install -r Tools/VideoToolsHelper/requirements-dev.txt
cd Tools/VideoToolsHelper
python3 -m pytest -q
python3 -m ruff check helper.py media.py conversion.py tests
```

The integration tests require FFmpeg and FFprobe on `PATH`. They create synthetic video
fixtures and verify clipping, image extraction, rotation, conversion, cancellation, cleanup,
metadata preservation, and protocol framing. The build script separately verifies the
frozen helper against bundled FFmpeg and FFprobe executables.

Conversion uses the already bundled FFmpeg build and adds no external application,
download, codec library, or network request. It maps every supported source track
explicitly and does not transcode audio or subtitles implicitly. Unsupported target
containers, dynamic HDR, or unsafe pixel-format changes fail without publishing an
incomplete output. Video re-encoding is lossy even at the selected high-quality preset.

# Screenshot defaults and real encoding regression

Run `bash Tools/ScreenshotPreferenceTests/run.sh` on macOS after fetching the
application's FFmpeg and libmpv dependencies. Missing dependencies fail the test;
they are not treated as a passing skip. The runner type-checks for macOS 10.15
Intel and executes natively on the host.

The test compiles the unmodified production `ScreenshotFormat` enum with an
isolated preference-store boundary. It checks the actual registered defaults,
the existing UI/engine bindings, and all unchanged persisted enum identifiers.
Random UUID preference domains prove that an implicit PNG default becomes JPG
but explicitly saved formats survive an upgrade and a fresh process. The real
application's preference domain is never opened or changed.

The native test also decodes generated landscape and portrait videos with the
application's real libmpv. It captures `video` and `subtitles` screenshots with
JPEG quality 100, tests explicit PNG/JPEG selections, and verifies extensions,
file magic, ImageIO decoding, and original pixel dimensions despite display zoom.
No filename-only conversion is used. JPEG is still a lossy format at quality 100;
PNG remains available for lossless output. This is a software-decoding regression,
not hardware decoding, HDR display, or visual color-fidelity acceptance.

Optional `SCREENSHOT_PREFERENCE_SOURCE_ROOT`, `SCREENSHOT_TEST_LIBRARY_DIR`,
`SCREENSHOT_TEST_INCLUDE_DIR`, and `SCREENSHOT_TEST_FFMPEG` overrides support
regression against a separate source tree or the source-built CI dependencies.

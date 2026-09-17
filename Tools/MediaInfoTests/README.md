# Native media information regression tests

Run `bash Tools/MediaInfoTests/run.sh` on macOS after building `deps/executable/ffmpeg`
and `ffprobe`. Xcode Command Line Tools, Python 3, and a WindowServer session are
required. Tests use generated fixtures, temporary app bundles, and a private
pasteboard; no personal media, user clipboard, or external network is needed.

- `LocalizationTests.py`: production label coverage and locale/placeholder parity.
- `VideoReaderTests.run.sh`: real video/audio/subtitle tracks, component depth,
  color/HDR evidence, rotation, cancellation, timeouts, output limits, and protocol
  isolation. A loopback listener verifies that referenced HTTP media is not read.
- `ImageRun.sh`: real raster/animated formats, orientation, explicit timing,
  camera allowlist, PDF units, safe SVG declarations, and unchanged source bytes.
- `LoaderRun.sh`: the production bundle-relative probe path and complete snapshots,
  with mutation/replacement and stale resource-value regression coverage.
- `RoutingRun.sh`: foreground media ownership, source changes, stopped/network
  media, and owner-window closing.
- `WindowTests.sh`: real AppKit lifecycle, selectable values, copy/refresh, stale
  result isolation, scrolling, layouts, and localized light/dark snapshots.

These are metadata tests, not a full-frame video scan or a claim that every codec,
container, malformed file, or camera format is supported by the operating system.

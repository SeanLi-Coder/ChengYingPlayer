# AV1 playback regression tests

Run `bash Tools/AV1PlaybackTests/run.sh /absolute/path/to/candidate-deps`.
The default dependency directory is the repository's `deps`. This suite requires
the AV1 VideoToolbox backport and verifies the actual dylib build-record hashes.
It creates no application bundle or visible window and reads no user media,
preferences, browser data, or network resources. Each compiler and executable has
an external timeout; generated files are confined to an owned temporary directory.

Coverage:

- Apply the exact SHA-locked backport with zero fuzz to verified FFmpeg 7.1.5
  originals. Reject preexisting empty files, dangling or regular symlinks, and
  malformed or broadened new-source markers before changing any source file.
- The native FFmpeg AV1 decoder advertises a VideoToolbox hardware configuration.
- The production Swift backend-capability helper compiles and returns true against
  the actual libraries; the whitelist retains a separate hardware-capability gate.
- The statically linked dav1d decoder decodes all 24 frames of both 8-bit and
  10-bit fixtures, preserving 192x108 display dimensions and the source bit depth.
- Actual libmpv loads each fixture in software and `videotoolbox-copy` modes,
  performs four exact seeks, plays to EOF, and tears down without a hang.
- A host without AV1 hardware must select software fallback in both modes.
  A hardware-capable host must actually select `videotoolbox-copy` in that mode.

This is a headless decoder test, not a display, HDR, ICC, GPU rendering, or 4K soak
test. In particular, an M2 software-fallback pass is not evidence of M4 AV1 hardware
decoding. Keep the existing render and soak suites as independent release gates.

The verified original `ffmpeg-7.1.5.tar.xz` is read from `SOURCE_CACHE_DIR` or
`deps/sources`; the suite does not fetch dependencies. To additionally prove that
the production Swift gate rejects an actual unpatched baseline, set
`AV1_BASELINE_DEPS=/absolute/path/to/old-deps`. Do not point that optional negative
control at already-patched libraries.

## Synthetic fixtures

The base64 files contain only FFmpeg's generated `testsrc2` pattern, not third-party
video. Both have 24 frames at 12 fps. They were generated with FFmpeg 9.0.2 and
SVT-AV1 4.2.0 (the encoder normalizes preset 13 to preset 11):

```sh
ffmpeg -hide_banner -loglevel error -nostdin \
  -f lavfi -i 'testsrc2=size=192x108:rate=12' -frames:v 24 -an \
  -c:v libsvtav1 -preset 13 -crf 35 -svtav1-params 'lp=2' \
  -pix_fmt yuv420p -f ivf av1-8bit.ivf
```

The 10-bit fixture uses `-pix_fmt yuv420p10le`. `run.py` pins the SHA-256 of
each decoded IVF file before execution. A system AV1 encoder is not needed to run
the tests. The playback backend stays pinned to the project's own FFmpeg 7.1.5
and dav1d sources; the external encoder was used solely to create test data.

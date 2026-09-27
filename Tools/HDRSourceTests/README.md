# Dolby Vision base-layer source regression

Run from the repository root on native Apple Silicon macOS, with `meson`,
`ninja`, Python 3 and Xcode command-line tools available:

```bash
bash Tools/HDRSourceTests/run.sh
```

An optional first argument selects another playback dependency directory, using
its actual `mpv-config.h`, FFmpeg headers and `libavutil.59.dylib`.
`SOURCE_CACHE_DIR` selects the verified source-archive cache. The test creates and
cleans up its own temporary build directory; it does not change existing playback
libraries or read private media.

The runner verifies and extracts the locked mpv 0.38.0, libplacebo 6.338.2 and
libplacebo build inputs, builds a small static libplacebo with Dolby Vision
metadata support, and compiles real `mp_image.c` and its dependencies under
ASan/UBSan. It first demonstrates that the original source interprets a synthetic
HLG base layer as PQ. It then applies the complete locked patch pipeline and
requires the corrected path to pass.

Synthetic AVFrames exercise HLG-compatible Dolby Vision, PQ-compatible Dolby
Vision, SDR-compatible Dolby Vision, and plain SDR/PQ/HLG. Checks cover actual
libplacebo metadata mapping, fallback after decoder light/peak inference,
original HDR metadata, attribute copies, AVFrame tags and side-data round-trips,
and reconfiguration when base-layer transfer or static mastering metadata
changes, without reconfiguring for per-frame HDR metadata. The actual extracted
`vf_format.set_params` checks explicit transfer changes and reinference; source
wiring checks require fallback before GL inference and format-filter overrides.

This is a metadata and source-behavior regression, not a pixel or display test.
`Tools/HDRRenderingTests` provides separate real embedded-OpenGL pixel coverage;
distribution checks must also confirm that the shipped library was built with
these exact patch bytes and source hashes. No external test hooks are added to
the public libmpv ABI.

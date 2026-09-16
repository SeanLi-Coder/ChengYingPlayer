# Actual 4K playback soak

Run on a Mac with the source-built playback libraries and media tools:

```sh
bash Tools/PlaybackSoakTests/run.sh
PLAYBACK_SOAK_SECONDS=600 bash Tools/PlaybackSoakTests/run.sh
```

The default is 180 seconds; `PLAYBACK_SOAK_SECONDS` accepts 60 to 14400 seconds.
The test generates its own six-second, 3840x2160, 24 fps H.264 8-bit and HEVC
Main10 clips. It never reads user media, playback settings, cookies, or network
resources. Fixtures and the compiled executable are removed on completion.

This is not a null-video-output test. It uses the application's actual pinned
libmpv, a real accelerated CGL 3.2 context, and the libmpv OpenGL render API with
advanced control enabled. Every frame is rendered to a real 4K framebuffer.
Sparse GPU pixel reads verify changing output. A separate controller thread
keeps synchronous player calls away from the render thread. Three generations
exercise full decoder/render/context release and recreation, while looping,
seeking, changing speed, and switching between codecs. Even the shortest run
must load both codecs in each generation; the switch interval is shortened
automatically so that the same warm-up and transition coverage still applies.

Hardware mode is the default and requires `hwdec-current=videotoolbox` for both
codecs; silent software fallback is a failure. The renderer and decoder mode
are printed explicitly. A virtual CI Mac may not offer a usable accelerated
context or VideoToolbox; that is not evidence of a playback regression and
must not be described as a successful hardware test. On such a runner, an
explicit software decode run is possible:

```sh
PLAYBACK_SOAK_MODE=software bash Tools/PlaybackSoakTests/run.sh
```

Software mode still requires real CGL rendering and labels itself as software
decoding. Neither mode is a substitute for the complete AppKit/CAOpenGLLayer
window, fullscreen, display-reconfiguration, HDR-output, or multi-hour test.
The generated Main10 clip is 10-bit SDR, not HDR. Six-second repeats exercise
long-lived resources but cannot represent every long-file container or codec
feature. No claim of all-video or all-driver stability follows from a pass.

The test samples its own resident memory and physical footprint once per second,
checks playback/GPU-output progress, and compares warmed-up median windows.
The 256 MiB growth and 2 GiB absolute limits are intentionally broad regression
guards for this isolated fixture, not application-wide memory limits. Separate
system processes such as WindowServer and VTDecoderXPCService are not measured.
Driver cache differences should be investigated rather than hidden by raising limits.
An external watchdog bounds even a driver or core deadlock. dav1d is statically
linked into libavcodec: the test verifies the built library hashes and exact
pinned dav1d source record, then checks that the executing FFmpeg library exposes
the libdav1d decoder. It does not inspect an unrelated or unused decoder dylib.

Relevant upstream history:

- [AV1 decoder crash and mismatched universal slices](https://github.com/iina/iina/issues/5712#issuecomment-4064217941)
- [Corrected IINA 1.4.2 build 164](https://github.com/iina/iina/releases/tag/v1.4.2-build164)
- [Large video misread as artwork fix](https://github.com/iina/iina/pull/5818)

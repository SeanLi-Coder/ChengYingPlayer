# Real ICC ownership and color-management regression

Run on macOS with Command Line Tools and the actual source-built playback stack:

```sh
bash Tools/ICCProfileTests/run.sh
CHENGYING_TEST_SOFTWARE_GL=1 bash Tools/ICCProfileTests/run.sh
```

This links the actual selected libmpv and verifies the loaded library path. It
creates a real offscreen CGL context, trying accelerated OpenGL first and Apple's
Generic Float renderer if necessary. No window, NSApplication event loop, network,
user media, user settings, FFmpeg executable or alternate software-render API is
used. Missing OpenGL capability is a hard failure, not a skip. A 120-second process
deadline bounds driver/core deadlocks. All generated files live in a private
temporary directory and are removed afterward.

The test obtains genuine macOS sRGB and Display P3 ICC data, copies it to ordinary
caller-owned guarded allocations, and submits `MPV_RENDER_PARAM_ICC_PROFILE`.
It checks that parameter fields, profile bytes and guards remain unchanged, then
immediately overwrites and frees caller storage before subsequent rendering,
duplicate submission, profile replacement, clearing and context destruction.
The pre-fix mpv 0.38 GPU backend mistakes this borrowed memory for a `ta`
allocation and aborts on the first disabled-auto submission; that is a regression
failure, never converted into a passing result.

An isolated four-color 64x64 PPM is generated in-process and decoded/rendered
through libmpv's actual OpenGL/LCMS path. Full framebuffer RGB comparisons require
different sRGB/P3 transformations, identical repeated/restored transformations,
and restoration of unmanaged output when the profile is cleared or ICC is
disabled. This proves ICC is actually applied, not merely that the API no longer
crashes. It does not claim wide-gamut display calibration or HDR correctness.

Auto-mode changes and the next ICC submission are deliberately not separated by
a render, so a stale renderer option cache cannot hide behind an incidental
frame. A small fail-closed source-wiring check also requires the real Swift app
to enable auto mode before profile submission and propagate API errors; two
explicit source mutations verify that guard. It is not represented as a compiled
Swift or complete application UI test.

`ICC_PROFILE_LIBRARY_DIR` and `ICC_PROFILE_INCLUDE_DIR` can select an isolated
candidate playback build before installation. They default to `deps/lib` and
`deps/include`. No source, allocator, renderer or ICC implementation is mocked.

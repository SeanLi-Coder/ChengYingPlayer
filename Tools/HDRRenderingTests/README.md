# Actual SDR/PQ/HLG rendering regression

Run on macOS after the source-built playback libraries are installed:

```sh
bash Tools/HDRRenderingTests/run.sh
CHENGYING_TEST_SOFTWARE_GL=1 bash Tools/HDRRenderingTests/run.sh
```

The test creates isolated 10-bit lossless FFV1/Matroska fixtures directly with the
locked FFmpeg libraries. It needs neither an FFmpeg executable nor downloaded
media. The eight neutral patches represent 0, 1, 10, 50, 100, 203, 400 and 1000
nits; SDR values above 203 nits are clipped when generating the SDR reference.
PQ uses the SMPTE ST 2084 transfer formula, and HLG uses the ARIB STD-B67 transfer
formula with a 1000-nit display and 1.2 system gamma.

Each fixture is decoded by the selected actual libmpv and drawn into a real CGL
framebuffer with a genuine macOS sRGB ICC profile. The test checks the loaded
library path, decoded dimensions and transfer metadata, then reads real pixels.
It requires neutral grays, monotonic brightness, retained midtone detail, usable
highlights, the expected SDR transfer response, and distinct PQ/HLG/SDR responses.
This catches loss of HDR transfer handling and gross clipping/tint regressions.
It does not claim reference tone-mapping accuracy or wide-gamut color accuracy.

These synthetic fixtures contain no Dolby Vision RPU. Dolby Vision color-state
restoration requires a separate source-level synthetic AVFrame regression, and
an explicitly authorized local sample can be checked privately against its
backward-compatible base layer. This test alone is not proof that a Dolby Vision
regression has been fixed. It also does not cover display EDR, Core Animation
composition, or hardware decoding.

The process never reads player preferences or starts a GUI. Temporary media and
pixel outputs are removed on exit. Missing real OpenGL capability is a failure,
not a skipped rendering pass. Each native run has a 90-second deadline.

`HDR_RENDERING_LIBRARY_DIR` and `HDR_RENDERING_INCLUDE_DIR` select an isolated
candidate library and headers before installation; defaults are `deps/lib` and
`deps/include`.

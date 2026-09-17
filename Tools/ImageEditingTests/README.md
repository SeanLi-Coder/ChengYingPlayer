# Image editing regression tests

Run `bash Tools/ImageEditingTests/run.sh` on macOS. The test compiles the real
`ImageEditor`, `ImageDocument`, and `ImageConverter`; it does not start the app,
read user preferences, or access the network. All generated images and exports
live in a private temporary directory removed when the runner exits.

The pixel fixtures cover clockwise quarter turns, negative and extreme turn
values, oriented-axis flips, top-left integer crops, operation ordering, padded
rows and cropped providers, 1-bit grayscale, straight alpha, 16-bit integer
precision, floating-point extended color, ICC profiles, and resizing. Invalid
or overflowing dimensions, out-of-bounds crops, and source-size mismatches must
fail explicitly.

Cancellation checks cover identity, rotation, crop, and resize requests. Real
callback-backed image providers cancel during pixel acquisition and CoreGraphics
drawing, proving that cancellation after work begins cannot return a finished
image without depending on sleeps or machine speed. The orientation loop also
checks cancellation every eight source rows.

Actual ImageIO GIF/APNG and multipage TIFF files exercise frame counts, loop
counts, nonuniform durations, conversion compatibility, source preservation,
exclusive `_edited` publication, collision handling, and cleanup after failure
or cancellation. When `deps/executable/chengying-image-codec` and native WebP
decoding are available, the same suite runs the actual WebP encoder with edited
frames and verifies their decoded pixels and profile. Missing WebP support is
reported as an explicit skip.

The final compile also type-checks the production backend for the existing
Intel/macOS 10.15 deployment target. This is not a visual UI test.

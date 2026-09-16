# Honest CI graphics capability handling

`run_with_capability_policy.sh` preserves its child's exact exit status except
for capability status 77 in an explicitly opted-in **software** test on GitHub
Actions. A missing CGL 3.2 renderer is shown as **SKIP**, with a warning and job
summary; it is not a renderer, pixel, or hardware-decoder pass.

The native soak and viewport harnesses only return 77 when their initial
accelerated and Apple Generic Float CGL 3.2 context attempts both fail in
software mode. Any later failure stays fatal. This does not change production
rendering or suppress the separate decoder, libmpv, AppKit and built-App checks.
The production player already tries accelerated and Generic Float renderers
with both core and legacy profiles; these framebuffer/pixel harnesses require
the narrower CGL 3.2 API and must not silently substitute a null video output.

Run `python3 Tools/RenderTestSupport/test_policy.py` for 108 boundary combinations.
The test invokes tiny exit-code fixtures, not a fake media player. Successful
local native tests still execute the actual decoder, GPU and pixel assertions.

After building the playback libraries, `bash Tools/RenderTestSupport/test_native_capability.sh`
compiles the complete production soak harness with only `CGLChoosePixelFormat`
replaced by an explicitly unavailable boundary. It verifies one fatal hardware
attempt versus two software attempts returning 77, without opening any media.
This boundary test is not evidence of successful graphics rendering.

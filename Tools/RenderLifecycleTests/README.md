# Rendering lifecycle regressions

Run `bash Tools/RenderLifecycleTests/run.sh` on macOS with Command Line Tools.

The suite mechanically extracts the production `ViewLayer` declarations, complete initializers and destructor, CGL factories, and CGL copy methods. It also extracts the complete `VideoView.uninit` and `startDisplayLink` methods. Only app-specific dependencies and unrelated drawing APIs are boundary doubles; the layer superclass, CGL allocations/reference counts, timers, dispatch queues, and production pthread read/write locks are real. Intel macOS 10.15 typechecking and native Address Sanitizer execution are included.

Repeated CGL copy/release cycles verify Core Animation ownership independently of the layer's own reference. Shadow creation/destruction verifies balanced retention, including a shadow outliving its model layer. Shutdown deterministically schedules a callback needing the production read lock while the stop boundary joins it, proving the renderer is not freed too early and avoiding the old lock inversion. The boundary join has a two-second timeout so old code fails without hanging the test runner. A late start request must not restart an uninitialized renderer.

`RENDER_LIFECYCLE_SOURCE_ROOT` can point at an earlier checkout for old-fail/new-pass comparisons. Optional test groups are `copies`, `shadows`, and `shutdown`.

On a Mac with an active display, `bash Tools/RenderLifecycleTests/run_live.sh` independently verifies that actual `CVDisplayLinkStop` waits for an in-flight callback. This probe does not change the display configuration or open any media.

These are lifecycle regressions, not proof that every codec, GPU driver, HDR monitor combination, or multi-hour 4K playback session is crash-free. The original issue history is not enough to identify one particular failure without a sample file or crash report.

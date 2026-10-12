# Paused first-video preroll regression

Run `bash Tools/NativePrerollAudioTests/run.sh` on an Apple Silicon Mac with
macOS 14.4+, a WindowServer session, and the repository FFmpeg dependencies.
The runner creates synthetic local fixtures in a unique ignored `build/`
directory. It does not open personal media, create an application bundle,
change an installed player, or modify system permissions.

The executable compiles the production decoder, sample gate, output, and
session directly. It mounts the production display layer in its own temporary
NSWindow and reads `displayedPixelBuffer()` only when the shared clock rate is
zero. Nine YUV pixel locations must match the independently decoded first
frame. Pause must keep both clock and volume at zero; enqueue counters alone
are not accepted as proof of a displayed image.

Both FFV1/PCM and H.264/AAC inputs have a one-second delay before their first
video frame, with enough preceding audio to fill the real audio renderer.
The H.264 fixture uses CRF 18 and forced B-frame decisions; FFprobe must observe
actual decoded B frames before the tests compile. Lossless x264/CRF 0 silently
disables B frames and is not accepted as evidence of frame-reordering coverage.
After resuming, every accepted audio sample's PTS and end time is compared in
order with an independent complete decode. Controls cover ordinary media,
autoplay's in-pump preroll transition, backwards seek, A/B including a range
with no video, rapid media replacement, audio-only playback, stop, and shutdown.
An excessive first-video gap must fail with `bufferLimit` within three seconds,
not hang until the generic ten-second preroll timeout.

`NATIVE_PREROLL_NEGATIVE=1 bash Tools/NativePrerollAudioTests/run.sh` changes
exactly one condition in a disposable source copy: it disables the new holding
path. All fixtures and assertions stay unchanged. This command must fail;
never report a failed negative control as a passing production test.
`NATIVE_PREROLL_SANITIZER=thread` enables Thread Sanitizer for both languages.

`NATIVE_PREROLL_FLUSH_DELAY=1` enables a separate controlled asynchronous-flush
case. A mechanically checked disposable output copy delays acknowledgement of
each **real** `AVSampleBufferVideoRenderer.flush` callback by 300 ms. It leaves
the real flush calls, pending-count increments/decrements, and DispatchGroup
enters/leaves intact. The harness issues twelve real flushes before open issues
another one, and verifies the gate is still occupied. This is an intentional
completion-ack scheduling experiment, not a claim that the platform naturally
takes 300 ms or that this run uses completely unmodified output source.

Run that case once normally and once with `NATIVE_PREROLL_NEGATIVE=flush`.
The second run only removes the session's pending-flush admission barrier and
its preroll drain ordering fix; it does not disable the new FIFO. Its original
per-sample timestamp/order assertions must fail when later audio overtakes
held leading audio. The fixture and delayed-ack output copy are identical in
both runs. Default and sanitizer runs still compile the unmodified production
output; the existing display/rendered suites separately cover that path.

The new audio FIFO is bounded by 256 sample buffers, 8 MiB, and a three-second
lead from the seek/open lower bound. It shares the existing 128 MiB budget with
submitted output. One additional decoder-pending sample is separately capped
at 128 MiB, preserving the previous normal 4K backpressure behavior. These are
application queue bounds, not total process memory promises; codec internals
and AVFoundation allocations are outside them. The test does not claim
arbitrary audio/video interleaving support, physically visible presentation,
audible audio continuity, or synchronization verified through speakers.

## Bounded failed-readback evidence

The original 117 checks, three-second pixel-readback verdict and 105/110-second
watchdogs are unchanged. Each harness keeps a fixed 1,024-entry numerical ring
of accepted-sample timestamps, snapshot phases and existing worker queries.
Only a failed pixel verdict prints this ring, after recording the original
failure; it does not wait for another image or turn a later image into a pass.
No pixel values, media contents, personal filenames or browser data are logged.

The readback distinguishes a raw nil buffer, incorrect dimensions/format/plane
count, a pixel-buffer lock failure and a missing plane base address. A nonzero
clock rate is separately recorded because no readback is attempted then.
Renderer status/error code, both timebases, readiness, flush generation and
accepted counters are read on the existing worker queue. View/layer ownership,
visibility and bounds are sampled on main. The old worker-side reflected FIFO
budget assertions remain unchanged; diagnostics add no reflected session state.
These samples are not a single atomic view of WindowServer presentation.

Readiness is not proof of an image: in the prior isolated diagnosis a nil buffer
and a subsequent valid buffer had the same ready-for-display and media-data
readiness values. A nil readback is not proof of a physically black display.
Locks, time calls and extra property reads introduce observer overhead and may
change scheduling. This instrumentation is evidence collection, not a fix or
an explanation of the earlier intermittent `twnu4i` failure.

`NATIVE_PREROLL_DIAGNOSTIC_NEGATIVE=1` mechanically changes exactly one checked
verdict expression in a disposable `main.swift`: the lifecycle "Seek shows a
current video image" check remains false for its original three seconds.
Production sources, actual readback and all other checks remain unchanged.
Expected output is 116 passes, one failure, `READBACK_FAILURE_TIMELINE` and exit
status 1. A successful buffer in this artificial negative must still be logged
as reason 0; this control does not reproduce the original nil-buffer failure.
This mode cannot be combined with the FIFO or delayed-flush controls.

Each run records the base commit plus SHA-256 manifests of all compiled source
inputs, source-transform scripts and all six synthetic fixtures. Post-run
source/fixture validation logs are written even when the executable fails.
The runner preserves the executable or log-writer failure status; a manifest
mismatch also fails. Diagnostic text and manifests can be collected without
publishing the fixture media or any personal files.

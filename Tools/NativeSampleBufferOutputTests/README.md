# Native sample-buffer output regression

Run `bash Tools/NativeSampleBufferOutputTests/run.sh` on Apple Silicon macOS.
The runner compiles a standalone command-line executable in an owned temporary
directory, initializes AppKit without creating an application bundle, and removes
only that executable and directory on exit. It does not change system permissions,
register a persistent application, read personal media, or modify audio devices.

The tests enqueue synthetic uncompressed BGRA video and silent stereo float PCM
through the production `NativeSampleBufferOutput`. They check default zero volume,
finite input validation, supported playback rates, a genuinely advancing shared
clock, pause, asynchronous seek anchoring, both-stream flush, system backpressure,
automatic audio flush notification forwarding, and asynchronous renderer removal.
Twelve repeated construction/rate/flush/shutdown cycles also verify zero-volume
reinitialization and release of the output object after asynchronous removal.
An isolated negative-test child intentionally calls shutdown from main and must
terminate on the worker-queue assertion. Its expected crash output is suppressed;
the test does not terminate or alter any user application.
The notification cases are explicit white-box fixtures, not actual device changes.

The output has no application-side frame queue. Its owner serializes all commands
and queries on a worker queue and uses a bounded pump. `isReady` is advisory:
framework readiness can change before the next enqueue, so the enqueue path also
checks readiness and reports backpressure. The owner retains at most its own bounded
pending samples and retries them without decoding more unbounded work.
Pass the worker to `init(workerQueue:)` to enable exact dispatch-queue ownership
assertions. `actualRate` reads the underlying timebase, not the requested rate:
a seek must await both a stopped clock and the new time anchor before resuming.
On macOS 14 and newer, every video queue operation and synchronizer attachment
uses `AVSampleBufferVideoRenderer`; it is not mixed with display-layer queue APIs.
Both streams report not-ready until all outstanding asynchronous video flushes
finish. Shutdown completion also waits for those flush callbacks without blocking
main. The older display-layer compatibility branch compiles for macOS 12 but is
not runtime-qualified by a test on a newer operating system.

`setRate` accepts pause or rates from 0.5 through 2.0. Spectral pitch processing is
selected explicitly. Other rates are rejected rather than silently muting audio or
changing the requested rate. The range is an integration qualification boundary,
not a claim that the Apple algorithm is incapable of a wider range.

The audio flush handler can run on any thread. Its owner must dispatch back to its
worker, validate the current playback generation, then pause/flush/seek/refill.
Removing the handler cannot retract a callback already executing on another thread.

These checks prove sample acceptance, clock behavior, validation and lifecycle;
they do not prove displayed pixels, audible output, A/V drift under load, HDR/EDR,
compressed codec support, multi-hour reliability, or M4 Max hardware acceleration.
Those require separate integrated playback validation.

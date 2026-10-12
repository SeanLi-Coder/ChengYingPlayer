# Native playback end-to-end displayed-pixel regression

Run `bash Tools/NativePlaybackRenderedTests/run.sh` on Apple Silicon macOS 14.4
or newer with an active WindowServer. The runner uses the repository FFmpeg
libraries, the local Swift/Clang SDK, and `/opt/homebrew/bin/ffmpeg` to generate
fixtures. `FFMPEG_BIN` may select another installed FFmpeg executable.

This is a real file-to-displayed-buffer test:

`synthetic file -> CYNMediaDecoder -> NativePlaybackSession -> NativeSampleBufferOutput -> displayedPixelBuffer()`

The production decoder demuxes and decodes local FFV1/PCM and H.264/AAC files.
The production session owns the output queue, handles commands, and schedules all
samples. The test never manually enqueues frames or moves the output clock. It
reads the real renderer's displayed pixel buffer on the session's owner queue,
after confirming that the actual timebase is paused. A bounded sample observer
prints only each revision's first accepted audio/video timestamp for diagnosis;
that acceptance is not used as evidence of displayed pixels.

Each timeline has red, green and blue intervals; a separate file contains purple.
Both video and audio streams are present, but audio samples are silent and output
volume is asserted to stay at zero. Nine points from the actual 160x90 NV12
displayed buffer must match the expected YUV components within one code value.
The fixture generator explicitly assigns BT.709 limited-range metadata before
encoding, and independently decodes selected source pixels with FFmpeg to verify
that its source values match the test's constants. This prevents fixture-side
automatic color conversion from being mistaken for a renderer bug.

Coverage includes paused open, forward/backward seek, actual clock-driven playback
and pause, stable paused pixels, eight rapid file replacements, stale-generation
rejection, stop/clear/reopen, and asynchronous close with no displayed residue.
The test obtains the session worker using read-only reflection so it can inspect
production renderer state without widening the app API.

Only a transient CLI-owned AppKit window is created. No `.app` is built or
registered, no desktop screenshot is captured, and no personal media is read.
The window closes and output shuts down before successful exit. The runner removes
its executable and object file but retains synthetic fixtures and `results.log`
under its printed, uniquely named `build/native-playback-rendered-tests.*` path.
Missing WindowServer/API support exits 77 as unverified; watchdog expiry exits
124 as failure. Pixel failures are not converted into skipped or passing checks.

For controlled regressions, `NATIVE_PLAYBACK_SESSION_SOURCE=/absolute/path.swift`
can substitute only the session implementation while all other production code,
fixtures and assertions remain unchanged. During development, a negative control
and the initial anchor-only change both reproduced H.264 paused seek with no video
sample enqueued; the timed preroll exit was investigated rather than relaxing the
pixel assertion.
With the modern output held constant, a second negative control that removes only
the paused-first-video guard fails 1 of 66 assertions at the same 1.7-second seek.
The complete production implementation passes all 66 assertions: the first video
sample arrives at 1.7 seconds and the actual displayed buffer contains green.

Limits: displayed-buffer readback is not a physical-screen screenshot, HDR/EDR or
color-management certification, audible-output/A-V drift measurement, long-file
soak, or M4 Max AV1 hardware proof. This standalone harness does not prove that the
shipping app UI has migrated away from its compatibility playback backend.

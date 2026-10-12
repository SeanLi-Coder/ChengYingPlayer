# Actual native displayed-buffer verification

Run `bash Tools/NativeSampleBufferDisplayTests/run.sh` on Apple Silicon macOS
14.4 or newer with an available WindowServer session. The command-line test opens
one temporary AppKit window and uses the production `NativeSampleBufferOutput`.
It creates no `.app` bundle, reads no user media, captures no desktop screenshots,
requests no screen-recording access, and produces no persistent application copy.

The actual verification uses
`AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer` (imported in Swift as
`displayedPixelBuffer()`). Apple's SDK states that this returns the pixel buffer
currently displayed in the renderer's target, but returns nil while its rate is
nonzero. Every sampled playback interval is therefore paused first and waits for
the **actual underlying timebase rate** to become zero. The returned pixels and
attachments are only read, never changed.

Each synthetic frame has a different solid color. Nine points in the returned
BGRA pixel buffer are checked against the expected original bytes with a tolerance
of two code values. Assertions cover initial paused display, timestamp-driven
red-to-green progression, paused-frame retention beyond a queued frame's wall-time
deadline, flush with and without displayed-image removal, forward seek replacing
the queued old blue image with new yellow/purple images, backward seek, and final
image removal during asynchronous shutdown. Negative color checks ensure the test
does not mistake the most recently enqueued frame for the displayed frame.
Thirteen overlapping asynchronous flush requests also verify that all callbacks
finish before a replacement frame is accepted, that the final clearing request
removes the old image, and that no late flush erases the new displayed pixels.

This is stronger than sample acceptance or a rendering-status flag. It verifies
the renderer's actual selected displayed buffer, but it is **not** a physical
screen capture or proof of final display color management, HDR/EDR brightness,
audible audio, A/V drift, compressed decoder correctness, or long-duration playback.
Those remain separate integration and target-hardware acceptance work.

Missing WindowServer access or unavailable displayed pixels are reported rather
than silently accepted. Test executable cleanup removes only the uniquely owned
temporary binary and its empty directory; the window is closed before normal exit.

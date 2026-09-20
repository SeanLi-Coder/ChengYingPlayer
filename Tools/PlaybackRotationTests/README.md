# Rotation teardown regression

Run on macOS with Command Line Tools and the actual bundled playback stack:

```sh
bash Tools/PlaybackRotationTests/run.sh
```

This compiles a native libmpv client, verifies the loaded library path, and decodes
a generated 0.6-second H.264 clip with `vo=null`, software decoding, no user config,
`keep-open=no`, and `loop-file=no`. It does not launch the App, access user media,
change preferences, simulate the core, or exercise OpenGL rendering. Every child
process has a 30-second deadline; a crash or timeout is a test failure. Generated
artifacts are private temporary files and removed afterward.

The cases observe real `on_unload`, `end-file`, and `on_after_end_file` boundaries
for natural EOF, explicit stop, replacement, and natural playlist advancement.
They restore rotation inside
`on_unload`, reproducing the App's cleanup while the decoder still exists, and
compare it with a post-teardown control. Every case must preserve the EOF/stop
reason, complete every hook, leave the core responsive, and restore the next
file's rotation to zero. A kept-open EOF case also changes rotation while paused,
seeks back to the beginning, requires a real decoder restart, then unloads at the
next EOF. The default suite must fail against the old library.

To reproduce the original unsafe property write on the unmodified mpv 0.38 core:

```sh
bash Tools/PlaybackRotationTests/run.sh unload eof
```

The reproduction intentionally exits unsuccessfully if the core aborts. The
unpatched library reproduces `play_current_file: loadfile.c:1922:
assert(mpctx->stop_play)` with exit status 134. Compare with the `after-end eof`
control, which survives on the same old library. This is a real playback core
regression; App keyboard dispatch and rendering require separate App validation.

`PLAYBACK_ROTATION_LIBRARY_DIR`, `PLAYBACK_ROTATION_INCLUDE_DIR`, and
`PLAYBACK_ROTATION_FFMPEG` can select an isolated candidate stack.

## Source regression without rebuilding the playback libraries

```sh
bash Tools/PlaybackRotationTests/run_source.sh
```

This verifies the checksum-pinned mpv archive, extracts the complete real
`mp_force_video_refresh`, `issue_refresh_seek`, and `queue_seek` functions and
their actual enum/seek declarations, and compiles them with Address Sanitizer
and Undefined Behavior Sanitizer. Only surrounding playback state and core
wakeup/time boundaries are controlled doubles. The test first requires the
original source to fail the exact EOF teardown invariant. It then applies the
production checksum-locked patch manifest and requires the same regression to
pass, along with relative seek coalescing, paused rotation, seek cancellation,
and every playback exit reason. Missing cached archives use the established
verified source download helper.

This source test does not prove a distributed dylib contains the patched code.
Run the native suite above against the source-built library before distribution.

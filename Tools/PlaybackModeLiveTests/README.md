# Real playback mode regression

Run from the repository root after building the playback libraries and bundled
FFmpeg:

```sh
bash Tools/PlaybackModeLiveTests/run.sh
```

The waiter has a separate deterministic test that does not initialize libmpv,
create an App, or use audio/video output:

```sh
python3 -B Tools/PlaybackModeLiveTests/run_wait_tests.py
```

It compiles the same `PlaybackModeWait` helper used by the live test, including
the eight-second deadline and rejection of results obtained at or after it. A
disposable negative-control copy restores the former second condition read and
must fail the true-then-false case immediately, not by timing out.

Historical CI run `38422286763` failed while settling paused A-B media before
any playback-mode change. Its entire step, including compilation, lasted about
2.55 seconds, below the eight-second wait. The old waiter reread its non-atomic
condition after a successful sample and could therefore fail before its deadline.
This deterministic defect is fixed without changing the live success predicates
or increasing time limits. The original log did not capture `seeking` or both
samples, so it does not establish this as the unique cause of that CI failure.

An optional first argument selects another complete dependency directory. Missing
dependencies fail the test; there is no capability skip. The runner generates two
short synthetic videos in a disposable directory and links the actual libmpv.
It compiles the production `LoopMode`, `PlayerCore.getLoopMode`, and
`PlayerCore.applyLoopMode`, and `MPVController.addSavedLoopModeHook` implementations,
with a small adapter to the real C API.
Extraction fails if the production method boundaries change.

Coverage includes mutually exclusive repeat properties, paused mode changes that
preserve position and A-B markers, actual single-file and playlist EOF wraps,
one-item playlist wrap, queue clearing, stopping and reusing a core, restoration
after stale file-local options at real loading barriers, and sequential EOF
behavior with automatic next-item playback both enabled and disabled. The stale
file-local fixture changes file repeat to playlist repeat during playback, then
disables repetition at the last item; this guards both EOF decision directions.
`keep-open=yes` is the normal player default; `keep-open=always` is the production
mapping for disabled automatic next-item playback.

This test uses null audio/video outputs, software decoding, a disposable mpv
configuration directory, and disabled config/resume loading. It does not launch the App, use user
media, read or modify App preferences, or require Keychain, Accessibility, or a
display. The hook test supplies an in-memory saved choice at the preference
boundary. Persistence and native UI dispatch are covered separately; this test
establishes real decoder/playlist behavior for the production option application.

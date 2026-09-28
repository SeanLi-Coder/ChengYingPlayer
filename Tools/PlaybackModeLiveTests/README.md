# Real playback mode regression

Run from the repository root after building the playback libraries and bundled
FFmpeg:

```sh
bash Tools/PlaybackModeLiveTests/run.sh
```

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

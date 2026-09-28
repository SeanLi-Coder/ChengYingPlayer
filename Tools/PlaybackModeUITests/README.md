# Playback mode UI regression tests

Run `bash Tools/PlaybackModeUITests/run.sh` on macOS with Xcode command-line tools.
The runner mechanically extracts production AppKit controls and menu actions, then
tests all three modes, selected state, accessibility values, tooltips, a 240-point
sidebar, both folder and queue views, and existing main-menu toggle behavior in
English, Simplified Chinese, and Traditional Chinese. It also checks the existing
repeat preference bindings, updated global-scope label, and checkbox label width.

The player boundary is in-memory. Tests do not create a real player, access media,
or read or write the application's preferences. Core persistence and mpv behavior
are covered by `Tools/PlaybackModeTests`.

Set `PLAYBACK_MODE_UI_SNAPSHOT_DIR` to an ignored output directory to also render
the real AppKit fixture at 240 and 320 points in each tested language.

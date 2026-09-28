# Playback mode persistence regression

Run `bash Tools/PlaybackModeTests/run.sh` on macOS with Xcode command-line tools.

The harness compiles the actual `PlayerCore` loop methods, preference read/write
methods, shortcut policy and loading/teardown hooks against a recording mpv boundary. It
checks global propagation, explicit off, legacy settings, shutdown protection,
A-B/pause/position preservation and file-load wiring. A temporary app with a random
bundle identifier uses real `UserDefaults`; separate writer and reader processes
verify file, playlist and off selections after process restart. The test removes
only its own random domain and never opens the real player or its preferences.

Registered defaults preserve existing advanced mpv loop settings until the user
saves either repeat preference. Thereafter the saved app mode wins at each file
load and after file-local unload backups restore, before playlist wrap decisions.
Explicit Foundation launch arguments retain their normal transient precedence
without changing the persisted selection. Finite-repeat and compound key commands remain mpv commands and are not saved
as an app-wide mode.

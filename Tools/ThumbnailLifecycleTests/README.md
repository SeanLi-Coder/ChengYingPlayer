# Thumbnail request lifecycle regressions

Run `bash Tools/ThumbnailLifecycleTests/run.sh` on macOS with Command Line Tools.

The suite extracts the complete current `PlayerCore` invalidation, thumbnail request,
and delegate method bodies, and uses the production atomic lock and player state.
The decoder and disk cache are controlled boundaries; the serial background queue,
main queue, and completion ordering are real. Address Sanitizer and Intel macOS
10.15 typechecking are enabled. No user media, preferences, or cache is read.

Cases cover same-path reloads, stale decoder and disk completions, disabled previews,
stop/shutdown states, damaged-cache regeneration, safe legacy width conversion,
bounded progress, immediate preview release, main-thread UI changes, and snapshot
cache writes when another file starts. `PlaybackLifecycleTests` additionally
executes the actual file-start, stop, and shutdown callers.

# Playback lifecycle regressions

Run `bash Tools/PlaybackLifecycleTests/run.sh` on macOS with Command Line Tools.

The suite mechanically extracts the current `PlayerCore` task declarations and complete `fileStarted`, `stop`, `shutdown`, `postNotification`, and background-cancellation bodies, plus `MPVController.getFilters` and `removeFilter`. No implementation is copied into the test cases. Only private access is relaxed in a temporary copy. The real `MediaInfoModels` notification names, `NotificationCenter` delivery, serial dispatch queue, main-queue completion ordering, and filter pointer operations run under Address Sanitizer. The native APIs and unrelated window/media state are controlled boundary doubles. Intel macOS 10.15 typechecking is included.

Deterministic semaphore ordering reproduces two overlapping file loads with an old completion delivered while the new matcher is running. Both stop and quit must wait until every task releases ownership. Filter cases cover negative/stale indexes, missing properties, malformed nodes, parse failures, write failures, memory cleanup, and successful first/middle/last/only-item removal.

Source-change checks verify the real sender, main-thread delivery, updated URL/resource flags, generation ordering, reopening the same path, and notification suppression after playback becomes inactive. Completing an older background task must not send duplicate or stale source events.

For an old-fail/new-pass comparison, `PLAYBACK_TEST_SOURCE_ROOT` can point at an extracted earlier revision. Optional groups are `lifecycle`, `filter-read-failure`, `filter-negative`, and `filter-write-failure`.

After fetching the application's playback dependencies, `bash Tools/PlaybackLifecycleTests/run_live.sh` runs the same extracted filter methods against actual libmpv C node trees and the production `MPVNode` parser, also with Address Sanitizer. It verifies unavailable-property handling, duplicate filters, valid removals, and boundary rejection without reading any user media or mpv configuration.

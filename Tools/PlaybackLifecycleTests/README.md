# Playback lifecycle regressions

续播接线后本套仍明确限定 MPV-only、resume-off。共享
`NativePlayerCoreTests/NoResumeTypes.swift`／`NoResumeMethods.txt` 只接受 nil
收据；新 native 保存分支、writer drain 和 MPV 自动保存抑制写入若被触达均
fail-fast，不模拟保存成功。实际 `stop`／`shutdown` 完整体和原断言保留。
输入校验包括两份共享边界、生产源与生成片。

原编译失败保留在 `build/resume-legacy-compile.6I1BLu/lifecycle-before.log`。
`PLAYBACK_LIFECYCLE_BUILD_ONLY=1` 只做 Intel 10.15 typecheck 和 ASan 编译，
不执行断言；修补后该模式通过。原普通命令随后通过全部 76 项 ASan 检查及
source/generated 输入核验（`lifecycle-leased.log`），Core 为 `d037183d…`。

Run `bash Tools/PlaybackLifecycleTests/run.sh` on macOS with Command Line Tools.

The suite mechanically extracts the current `PlayerCore` task declarations and complete `fileStarted`, `stop`, `shutdown`, `postNotification`, and background-cancellation bodies, plus `MPVController.getFilters` and `removeFilter`. No implementation is copied into the test cases. Only private access is relaxed in a temporary copy. The real `MediaInfoModels` notification names, `NotificationCenter` delivery, serial dispatch queue, main-queue completion ordering, and filter pointer operations run under Address Sanitizer. The native APIs and unrelated window/media state are controlled boundary doubles. Intel macOS 10.15 typechecking is included.

Generic handoff remains outside this MPV-only suite. Its boundary accepts only
nil ownership/restore receipts and verifies that invalidation has no native work
to retire. The owner and phase types have private initializers; route access,
phase creation/mutation, or restore ownership checks fail fast. This is not a
replacement generic state machine, and no production lifecycle branch is removed
to make extraction compile.

Deterministic semaphore ordering reproduces two overlapping file loads with an old completion delivered while the new matcher is running. Both stop and quit must wait until every task releases ownership. Filter cases cover negative/stale indexes, missing properties, malformed nodes, parse failures, write failures, memory cleanup, and successful first/middle/last/only-item removal.

Source-change checks verify the real sender, main-thread delivery, updated URL/resource flags, generation ordering, reopening the same path, and notification suppression after playback becomes inactive. Completing an older background task must not send duplicate or stale source events.

For an old-fail/new-pass comparison, `PLAYBACK_TEST_SOURCE_ROOT` can point at an extracted earlier revision. Optional groups are `lifecycle`, `filter-read-failure`, `filter-negative`, and `filter-write-failure`.

After fetching the application's playback dependencies, `bash Tools/PlaybackLifecycleTests/run_live.sh` runs the same extracted filter methods against actual libmpv C node trees and the production `MPVNode` parser, also with Address Sanitizer. It verifies unavailable-property handling, duplicate filters, valid removals, and boundary rejection without reading any user media or mpv configuration.

# Complete native playback application checks

## 独立续播候选：44 + 10 项，等待完整 App CI

`--include-resume` 新增两个独立的完整 App 进程，不删除或替代 baseline 的 95 项和 queue 的 54 项。当前仅完成测试实现和本机 CLI 准备检查；没有在本机构建或启动完整 App，也没有将环境伪装成 CI。新场景的真实运行结果和总耗时必须等待 GitHub-hosted macOS CI。

第一个 `resume` 进程要求 44 项独立断言：

- 启用真实续播偏好，使用原生暂停播放、非零位置 4.2 秒、1.25 倍速和真实音量滑块 37%。关闭窗口后，实际 watch-later 必须是 0600 的普通文件，仅含首行 `start` 与第二行 `speed`，不得记录音量或 A/B 预览区间。
- 关闭并完成 Core shutdown 后创建不同 Core。现有 watch-later 必须触发真正的 MPV 加载；直接查询 libmpv 的位置、速度、暂停和音量，并确认文件已被 MPV 消费。再等 0.2 秒重复检查；新打开的音量和滑块必须为 0。
- 真实剪辑面板先以 1.25 秒为基准，输入 4.2～5 秒的预览区间。实际 worker 必须已在该区间播放，然后在同一 main turn 调用 `finishNativePreview`、确认恢复回调仍 pending、立即执行真实窗口关闭。保存结果必须仍是 1.25 秒基准，不得变成 4.x 秒的临时预览位置。测试不暂停 worker、不构造快照、不直接修改 Core 私有保存状态。
- 分别在原生媒体仍打开时调用真实清除服务和修改真实 `resumeLastPosition=false`。随后关闭，旧位置和 LastPlayed 元数据不能重新写回。清除使用生产 Service barrier 和相同的 remove/recreate 语义；它不声称已验证设置面板的确认框。
- 最后保留一个实际原生暂停 Core，调用真正的 `NSApp.terminate`，由真实 AppDelegate 退出流程保存蓝色视频的 4.2 秒 / 1.25 倍速。`willTerminate` 必须确认所有已登记 Core 已关闭、原生层已脱离，并且隔离目录只有预期的有效记录。

第二个 `resume-verify` 进程要求 10 项断言：重新启动同一份测试 App，在原路径下检查上一进程真实退出留下的记录，再让新 Core 的真实 MPV 读取、消费它，并验证位置 / 速度和静音。读取完成后通过真实偏好关闭续播，再关闭 Core 和应用，不能重新生成已消费的位置。

两个进程具有不同的 run UUID 和独立 `resume/`、`resume-verify/` 报告目录。合成媒体和 marker 路径保持相同，避免改变 MPV 的路径摘要；两个结果文件分别为 `result.json` 和 `result-resume-verify.json`，读回不能覆盖或代替写入结果。各进程仍使用原有 110 秒内部期限和 150 秒外部期限。writer 失败则不启动 reader；reader 失败或超时保留 writer 证据，但整体验收失败。

隔离 watch-later 位于当前 `TestAppWorkspace` 管理的 `.noindex` 树内。唯一的生产文件测试接线是 `Utility.watchLaterURL` 下的 `CHENGYING_NATIVE_APP_TESTS` 条件分支：只有 Driver 完成 CI 身份、bundle UUID、marker、媒体、目录所有权及 0700 / 无 symlink 验证后才能返回该目录；普通版本和 baseline / queue 均不使用该分支。不会改变安装版的 Application Support 或权限。

baseline / queue 的续播偏好继续明确为 false；resume 场景才从 argument domain 去掉该键，并使用本轮独占 bundle ID 的真实持久偏好，使 opt-out 走实际 KVO。runner 最后只清除 `io.chengying.tests.native-app.<本轮 UUID>` 域并核实为空，任何配置清理失败均阻止整体成功。既有 `TestAppWorkspace` 的进程、挂载点、LaunchServices 和文件清理约束保持不变。

源码 / 测试 App / fixture 的 SHA-256 在各次实际运行前后检查；reader 还必须与 writer 的 fixture 清单完全一致。准备自测覆盖新增结果全集、缺失断言、错误退出、错误 UUID、跨进程源码或媒体变化、两种失败顺序、报告路径边界和清理确认。实际记录字段比较器还用正确、错误位置/速度、非有限值、额外音量/A-B/路径注释等 15 个输入进行 CLI 验证。这些检查和 declaration-only macOS 12 类型检查均不是完整 App 已通过的证据。

2026-10-13 最终本机准备证据为 `build/native-app-resume-preparation.HBvWQg`：59 项自测通过，实际测试进程退出 0；包括原有比较器、macOS 12 类型检查及原有 AppKit 退出调度 CLI 正负控。11 个相关源码文件（含 Utility 测试接线、真实 Service / Store）的运行前后 SHA-256 一致，独立复查通过。Driver SHA-256 为 `3922701899d754fa7fe54221a1062a63a11a69887c5198ac9295d73665ae8c91`。较早的 `JhbSme` 因 zsh 包装器使用只读变量名而未记录退出码和运行后身份，保留为不完整证据，不作为最终验收。当前没有 44/10 完整 App 通过结果。

## Current 95-check candidate: awaiting complete-App CI

The candidate retains all 92 baseline labels and their assertions, then adds three
window-state checks to the existing loaded generic handoff. The independent queue
scenario remains 54 checks. The previous frozen 92/92 result below does not prove
this new 95-check candidate has passed.

After the native nondefault playback state is actually ready, the driver dispatches
the real `alwaysOnTop` menu item's action to the same production main-window
controller. It first requires a visible windowed native player with a normal
window level, an off on-top indicator and untouched false MPV flags. The menu must
then raise the actual `NSWindow.level` to `.iinaFloating` and set its indicator,
while the idle MPV on-top flag remains false and MPV still has no path or renderer.
This prevents an accidental early MPV write from masking the handoff regression.

The existing real audio-delay menu action then initiates compatibility as before.
After its deferred effect and all original transport/viewport checks pass, a new
required check reads the same visible NSWindow, its actual level, the controller
indicator, and real MPV fullscreen/on-top properties. The same values must survive
the existing 0.2-second stable-state interval, recorded as a third required check.
No test code writes MPV window flags, assigns fullscreen state, or raises the
window directly. The automatically-float and open-fullscreen preferences are
explicitly false only in the existing isolated volatile test domain.

These three checks exercise the real application menu and MPVController event
route in CI. They do not enter or simulate macOS Spaces, prove stacking against
other applications, or establish true fullscreen-animation acceptance. The
110-second driver and 150-second process deadlines are unchanged. Local predicate
checks and declaration-only typechecking remain preparation evidence, not a
substitute for running all 95 checks in the disposable CI application.

Local preparation on 2026-10-13 passed all 47 tests in
`build/native-app-window-preparation.A01RXM`, including macOS 12 declaration-only
typechecking, ten real predicate positive/wrong-state inputs, preservation of the
original 92 labels, and rejection of each missing required label in the 95 set.
Driver SHA-256 is
`f19d431cd18e08c9ba9c75ff33d2175d8214d74552352734c3d473993ad09e52`.
Recorded preparation exit status is 0 and before/after input hashes match. This
run did not build or execute the complete application; 95-check App CI is pending.

## Latest frozen full-application result

CI run `38381002473` at `0455ab7c7dc207e3bc46349eda1ea6c148c1b891`
completed the real baseline **92/92** and separate queue **54/54** scenarios.
Both processes exited 0 without timeout. All five build/process identity reports
passed; the outer summary confirmed managed cleanup and exclusion of the test
driver from the normal production build. Each scenario has its own distinct
required labels and ends with all registered real cores shut down.

Evidence is retained in `build/native-ci-38381002473-app.v4Pomn` from artifact
`11804927964`. This is the first complete pass of these two scenarios, not a claim
that the whole workflow passed: its media-helper job failed to compile an older
PlaylistFilter boundary. It also does not cover subsequent uncommitted window
state and subtitle/LUT handoff changes, physical audio/HDR, M4 AV1 acceleration,
or a default-backend/release change. Earlier failures below remain historical
results for their own frozen sources.

`run.py` builds and runs a disposable, uniquely identified application only on a
GitHub-hosted macOS runner. It rejects local execution. The driver is included
only under `CHENGYING_NATIVE_APP_TESTS`; no test code is enabled in the release
executable. User media, browser data, installed application bundles and the
release preferences domain are not used.

The runner generates bounded SDR H.264/AAC fixtures and an embedded-subtitle
compatibility fixture in an owned disposable workspace. App startup validates
the run marker, file types, ownership and matching unique bundle identifier.
Cleanup uses the repository's managed test workspace. An assertion, process
timeout, incomplete report or cleanup failure cannot become a passing result.

## Preparation and execution

Local preparation (CLI probes and synthetic media only, not the complete App):

```sh
python3 -B Tools/NativeAppTests/test_runner.py
```

The existing CI build invokes the complete runner with its own paths:

```sh
python3 -B Tools/NativeAppTests/run.py \
  --source-packages /ci/source-packages \
  --report-directory /ci/unique-report-directory \
  --production-app /ci/assembled/ChengYing.app
```

Add `--include-queue` to also execute the separate 54-check queue scenario using
the same test build. The default executes only the current 95-check baseline
scenario. Both processes must succeed when the flag is present. The queue run
gets its own UUID, fixture marker and `queue/{app.log,result.json,summary.json}`;
it cannot overwrite or satisfy the baseline report. The disposable bundle is
still identified by the original build UUID. Both fixture roots must prove the
same managed workspace ownership, and the bundle's preferences remain isolated
from the installed application.

Both processes record and recheck SHA-256 inventories for the main App sources,
assets, build configuration and dependency headers, the actual built disposable
App bundle, and their own fixture/marker files. Source identity is first fixed
before the build; the queue process must match the same source and product
inventories as the baseline. Added, removed or changed inventoried inputs fail
the run. `process-status.json` retains the actual exit or timeout independently
of result validation; final identity checks also run on process failure/timeout.
`*-identity-validation.json` and `*-sha256{,-after}.json` remain diagnostic
artifacts. Only the outer summary can declare success after managed workspace
cleanup; a successful process alone does not prove successful cleanup.

The illustrative `/ci/` paths must be replaced by the existing workflow's
validated build outputs. Do not spoof the CI environment to execute this against
an installed app. Declaration-only `TypecheckBoundary.swift` is used solely for
local macOS 12 typechecking, never linked into the complete application.

## Loaded native-to-MPV handoff addition

The original loaded-handoff candidate required 92 distinct successful checks:
all previous 75 labels remained required, plus 17 loaded-handoff checks. CI run `38329363769` at `7f7e4bcc`
executed the candidate: 66 checks passed and the close/detach check failed.
The later compatibility and quit stages were not executed. Test App cleanup
completed. This is not evidence that the complete 92-check App has passed.

Subsequent CI run `38337569102` at `e4369f41` passed 70 checks. It proved the
previous close/detach assertion and initial embedded-subtitle fallback, but
failed `handoff_native_paused_red_ready` approximately two milliseconds after
opening the new core. The driver's paused-wait helper rejected a nil Session
before its bounded poll began, despite production inventory being asynchronous.
The loaded handoff and final quit stages were not executed; application build
and owned cleanup succeeded. The candidate now waits for the first actual
Session within the original twelve-second deadline, then pins both its identity
and the media generation before every query and callback. It does not substitute
a ready flag, relax pixel/clock conditions, or adopt a replacement owner.

After the original core has loaded the embedded-subtitle compatibility fixture,
the driver obtains another pristine core. It confirms that this core is not the
original, has no MPV media path or rendering context, and opens the existing
nine-second red/green/blue synthetic file through the native route.

The new core remains paused. Production bracket-key handling establishes A=0 and
B=5.5; an exact worker query and the displayed green sample verify position 4.2.
The real volume slider sets 37%, the speed menu sets 1.25x, and production viewport
keys select 1.5x with normalized pan `(+0.05/1.5, -0.05/1.5)`. Before handoff,
actual native worker state, visible markers and attached Surface geometry must
match these non-default values.

The real `menuChangeAudioDelay` action with `+0.25` triggers compatibility. The
driver never calls `requireMPVCompatibility` with a synthetic completion. It
requires all of the following:

- The same PlayerCore, local file and visible NSWindow survive the handoff.
- The captured native display layer is detached; native Session/Output/Surface
  references are gone and the real MPV rendering context has been initialized.
- Direct libmpv queries show position 4.2 within the production restore tolerance,
  paused playback, 37% volume and 1.25x speed; the actual volume slider also agrees.
- Direct libmpv viewport values equal `log2(1.5)` and the original normalized pan.
  A remains an enabled numeric zero, B remains 5.5, and loop count remains `inf`;
  the real slider's visible markers must agree.
- Actual `audio-delay=0.25` proves the deferred production menu action executed
  after restoration. A nonzero return from `sendAction` alone does not pass this.
- State and paused position stay stable for another 0.2 seconds.
- Real window close stops MPV. A subsequent explicit Core shutdown receives its
  genuine shutdown event and releases the rendering resources. Close alone is
  not incorrectly assumed to destroy the reusable MPV context.

The original two-active-core application-quit scenario then runs unchanged.
Its all-registered-cores shutdown check also includes the additional core, which
has already independently completed teardown.

## Evidence boundaries and deadlines

Post-handoff properties are read from the real MPV core, not from the retired
native model. They prove state restoration and same-window resource ownership;
they do not prove MPV physical-screen pixels, HDR color accuracy, audible sync,
arbitrary multi-track handoff or target-M4 hardware decoding. Native green-frame
readback uses the actual paused display buffer, not enqueue counts.

The 110-second driver deadline and 150-second process deadline remain unchanged.
Every recorded stage prints total elapsed time; the new handoff stages also print
their own elapsed time. Actual disposable-CI execution is required to establish
the total runtime. Partial reports are preserved on failure, and a timeout is a
failure, not permission to silently extend or disable the deadlines.

Preparation tests preserve the exact original label set, reject every missing
required check, typecheck against macOS 12, exercise the real numeric/geometry
comparators with wrong-state inputs, and retain the AppKit termination scheduling
positive/negative probe. These preparation checks are not a substitute for the
full application run.

## Independent native queue candidate

The opt-in second process uses only the existing bounded synthetic fixtures and
public production commands. It does not construct, mutate or reflect private
`NativeQueueState` storage. This is a candidate test, not an already passing
complete-application result.

The first pristine Core opens `[red, blue, red]` with `openMediaURLs`. Duplicate
paths must remain distinct stable playlist objects. Next, previous and explicit
selection of the second red entry must present the expected real paused display
buffer and position zero. The real volume slider sets 37% before transitions;
each new item must reset actual worker volume and the slider to zero. Same-turn
resume/toggle/pause commands during retirement must leave the new item paused,
verified by two real worker clock queries.

Near-end seeks avoid sleeping through entire clips without replacing real EOF:
off mode must end paused on the last entry; seeking the ended item to 4.2 then
resuming must advance from that target, not rewind. File repeat must wrap the
same duplicate entry; list repeat must wrap to index zero. Playing positions are
queried from the real worker, never accepted from the UI's cached position.
Paused wrap images and volume are checked again. A new single-file open issued
during a queued selection must cancel the old queue, detach its layer and remain
on the replacement blue file after another 0.2 seconds.

A newly opened queue then selects duplicate index two, sets A=0/B=5.5 through
real bracket keys, pauses at green position 4.2, and applies the same nondefault
37%/1.25x/viewport state as the baseline handoff. The real audio-delay menu must
install the entire queue into MPV, preserve its selected duplicate, apply the
deferred delay, and restore transport, viewport and A/B values in the same
window. One actual `MPV_NODE` snapshot must contain the complete ordered paths,
distinct nonnegative IDs, and exactly the correct current and playing entry.
Native layers/resources must be detached. These MPV state reads are not a
claim of post-handoff physical-screen pixel verification.

After independently closing and shutting down that Core, a second pristine Core
opens `[red, embedded-subtitle, blue, red]`. Selecting the unsupported subtitle
item must install the whole ordered queue in real MPV, select index one, retain
paused position zero and silence, and detach the prior native layer. This Core
also closes and shuts down. The actual application termination notification must
find both expected Cores and every registered Core fully shut down. The baseline
process's separate two-active-Core quit scenario remains unchanged.

Each process independently retains the original 110/150-second limits; the flag
does not extend either. Every stage prints elapsed time. Actual complete-App
execution is CI-only, and is still required to establish timings and outcomes
for these new 54 assertions. No default backend, media export, download, user
file, installed App or permission configuration is changed by this harness.

## Focused asynchronous paused-wait probe

This optional local CLI probe compiles the actual driver wait/pixel/comparator
methods with real Session/Output/Decoder and a small owned AppKit display window.
It is not a complete App, nib, menu or PlayerCore test. Its narrow boundary maps
ready state only from actual worker snapshots; no test-created ready snapshot is
injected. Fixture audio is silent.

```sh
NATIVE_PLAYBACK_DEPS=/absolute/verified/dependencies \
  bash Tools/NativeAppTests/run_paused_probe.sh
```

The default dependency path is the repository's `deps`; an override is verified
by the shared native dependency helper without replacing that directory. Source,
generated fixture/source and dependency manifests are checked again on exit,
including failing controls. Logs and actual exits are retained under the printed
`build/native-app-paused-wait.*` directory. The normal case delays real Session
creation by 120ms and requires a genuine paused image/clock. Additional cases
reject replacing the pinned Session or changing its media generation. A
single-variable old-first-session-guard control must fail before Session
creation, and both modes must clean up all decoder/output resources and their
owned CLI window. This addresses the observed immediate test failure; it does
not establish that the complete loaded handoff has now passed.

Local focused evidence before the final queue-key focus setup:
`build/native-app-paused-wait.07yI8I` passed delayed real acquisition in 0.322s,
Session-replacement rejection, generation-change rejection and full cleanup.
Its exact old-guard control exited 1 in under 0.1ms with
`PROBE_EXPECTED_EARLY_REJECTION: true`. Source/generated/dependency post-checks
passed. The wait helper itself is unchanged by the later queue-key focus setup;
the final candidate is rechecked before commit. Preparation suite
`build/native-app-queue-preparation.DYu9hr` passed 42 tests, including the existing
73 pixel/volume, 46 Surface geometry and 20 handoff numeric assertions plus 30
new actual queue-node comparator assertions. Those are preparation/focused
results, not complete App 92 or queue 46 success claims.

Final driver SHA-256:
`4e030500deab00a0d98fd24efbd760e9dda29a697fdfd06f848bbe8ea3db6c17`.
Its focused evidence is `build/native-app-paused-wait.XFSltk`: real delayed
acquisition passed in 0.576s; both ownership rejection checks and cleanup passed;
the old-guard control exited 1 after about 0.07ms with the exact early-rejection
marker. Source/generated/dependency identities matched after both runs. Final
preparation output and seven-file pre/post manifests are retained separately at
`build/native-app-queue-final.trDWRE`. These local checks do not run the complete
application or the 46 new queue assertions.

The subsequent opening-preference correction retains the baseline 92 checks
and adds one queue check (47 total). Playlist wrap now requires the new first
item to remain paused at position zero without sending a test pause command,
matching `pauseWhenOpen=true`. A separate natural EOF advance sets that
preference false and requires the next item's actual blue frame and advancing
worker clock, then restores the isolated argument-domain preference. A file
loop remains a same-media operation and must keep playing. The preparation
suite passed 43 tests for driver SHA-256
`2749e03ee67293973092a7d8f04f528d97ef9e5e5c8634c8288da6c790df0516`;
the complete 92/47 App scenarios remain unexecuted for this revision.

A subsequent third pristine Core adds seven cancellation checks (54 queue
checks total). It opens 256 explicit repeated local fixture URLs, invokes the
real audio-delay menu and observes a genuinely partial MPV append prefix. It
closes the window, immediately requests the blue file, and requires the actual
MPV list to contain only that replacement, paused at zero and muted in a visible
window. It checks the same ownership after 200ms, then closes and shuts down the
third Core. Termination must find all three distinct Cores fully retired. No
test directly changes the installer state or calls its stop acknowledgement.
This tests real media/clock/queue state, not post-handoff physical display pixels.
The preparation suite passed 44 tests for driver SHA-256
`4d7f5f4551d77138b4e63e5bd6cee1d7045f7ea50d897e5127906903de9cb947`.
An initial typecheck failure was the test-only `PlayerState` declaration missing
the production `.loading` case; adding that case preserved the driver predicate.
The complete 92/54 scenarios still require CI; neither process deadline changed.

The preview-close check captures a nonoptional real output layer before closing
the window. Its bounded diagnostic records preview/session/output ownership,
whether that captured layer still has a parent, native surface mode and GL
initialization. An absent output cannot accidentally satisfy a detach check.
No filename, user path or media data is included in that diagnostic.

The preparation boundary retains the production `MainWindowController!` type
instead of silently strengthening it to a nonoptional value. A diagnostic must
unwrap this property before storing a local alias. The preparation suite also
compiles the exact unguarded alias as a negative control; the macOS 12 typecheck
must reject it. This protects test-driver compilation, not window behavior.

## Nondefault handoff wait correction

CI `38361506765` retained 76 successful checks followed by
`handoff_native_nondefault_state` failure at approximately 16.11 seconds. The
previous green target had passed. Its aggregate failure label did not record
the query result, so the CI artifact alone cannot uniquely identify the cause.
The complete baseline and queue scenarios did not pass in that run.

The real CLI reproduction in `build/native-app-paused-wait.PnJ8Ui` established
one concrete driver defect: after paused position 4.2, A=0/B=5.5, volume 0.37 and
`setRate(1.25)`, an immediate worker query returned `unavailable`. A later real
query, within the bounded wait, reported exactly the intended paused position,
volume and rate, and the actual displayed NV12 buffer matched all 27 green YUV
reference values. `setRate` legitimately performs asynchronous seek/preroll;
the driver had treated that transitional response as an immediate failure. The
same one-shot pattern existed in the queue handoff preparation.

Both callers now use `waitForHandoffState`, backed by the existing single
twelve-second paused-wait deadline and one outstanding worker query at a time.
The real slider/menu actions, positions, markers, viewport geometry, rate and
pixel checks remain required. Only the handoff explicitly requests volume 0.37
with the original 1e-6 tolerance; all existing zero-volume waits retain exact
zero equality. Each caller captures its Session, media generation, URL, window
and display layer before sending the speed action. Those identities and the
public native/MPV event gate must still match before querying and on callback.
Core creates a new Session for every native route; a same-URL replacement cannot
be adopted. No private route state is read. A failed wait emits one bounded
state/ownership diagnostic without paths or media metadata. Baseline 92 and
queue 54 required labels, the 110-second driver deadline and the 150-second
outer deadline are unchanged.

The expanded focused runner remains a CLI test, not a full App or real menu
test. `HandoffWaitProbe.swift` mechanically uses the actual driver helpers and
pixel comparator, production Session/Output/decoder, nine-second synthetic
H.264/AAC RGB media and independently decoded FFmpeg reference pixels. Its small
PlayerCore service boundary does not verify real menu dispatch, markers or
viewport UI; those remain full-App/source-contract checks. The probe covers
correct 37%/1.25x values but does not claim end-to-end wrong-volume/wrong-rate
fault injection.

For deterministic command ordering, the probe reads only Session's immutable
worker `DispatchQueue` via `Mirror`, a test boundary already used by the native
fixtures. A semaphore barrier has bounded entry (one second), release (three
seconds) and exit (one second). While held, main submits the real volume/rate
commands followed by the real query or extracted wait, then releases it on all
paths. Both positive and negative controls use the same ordering; no snapshots,
sample buffers or readiness responses are fabricated. This is necessary because
uncontrolled main-thread preemption could allow preroll to finish before an
immediate query. The earlier natural `PnJ8Ui` result remains historical evidence,
not a flaky mandatory CI condition.

Final focused evidence: `build/native-app-paused-wait.rUhGfd`, run with
`NATIVE_PLAYBACK_DEPS="$PWD/build/native-av1-playback.7FMHum" bash Tools/NativeAppTests/run_paused_probe.sh`.
All six compilations exited 0. Child results were:

- `normal`: 0, original late-Session wait and both original owner checks pass.
- `old-first-session`: 1, exact former immediate nil-Session rejection.
- `old-handoff-capture`: 1, actual `unavailable` followed by correct real state.
- `handoff`: 0, bounded retime wait succeeds; replacement Session, changed
  generation and changed route are each rejected without a success callback.
- `old-one-shot`: 1, removing only retry causes exactly one failure on the real
  `unavailable` response, with no successful completion.
- `ignore-owner`: 1, removing the two ownership guards falsely accepts the
  replacement, producing exactly two successes instead of the required rejection.

The wrapper exited 0 only after exact expected markers/exits, explicit successful
worker ordering and complete Session/window cleanup for every mode. Source,
generated sources/media/object/executables and dependency identities all matched
after execution. Barrier failure or an unrelated process failure cannot satisfy
the negative-control contract. The same directory contains the final 45-test
preparation log and matching pre/post input hashes, including macOS 12
typechecking, all existing comparator assertions and termination controls.
Earlier `CcSP6Z` preserved a test-only missing-`try` compile failure; `ep5JsP` and
`JNjJis` were successful candidates before the deterministic barrier was added.

Final driver SHA-256:
`4926aeb4740b6c60dcb90bab7ffae17a0b53003173c3b02b9571df4487a57395`.
Final probe SHA-256:
`872f9502a5e0cb3a0ae205eae0380a191fb4e575b3d31d8238091a472e0f91cc`.
Final focused runner SHA-256:
`018bb55904b3d830f64a30730dc37d588fd1fd403aeb72841d3655da9e67bcbc`.
No production source was changed. This local evidence does not establish a
complete App 92/54 pass; that still requires the subsequent isolated CI run.

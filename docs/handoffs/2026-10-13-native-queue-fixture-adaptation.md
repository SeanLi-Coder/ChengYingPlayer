# Legacy fixture adaptation for explicit native queues

Branch: `codex/native-playback-core`. This is a test-interface handoff, not a
release or complete-App acceptance. No production file, test assertion, deadline,
default backend, installed application, or user preference was changed here.

## Boundary changes

- The shared `Tools/NativePlayerCoreTests/NoNativeQueueBoundary.txt` explicitly
  describes a single-media fixture: no queue admission, no queue installation,
  and no queue-owned restoration. Unexpected queue decisions or installation
  trap instead of manufacturing successful playback.
- The queue installation holder declarations are extracted verbatim from the
  current `PlayerCore`; runners compile the real `NativePlaybackQueue`,
  `MPVQueueInstaller`, and transport types where required. This is type and
  interface coverage, not a second implementation of their ownership policy.
- `publishNativeQueue()` permits only the nil-queue case, matching the production
  no-op used during ordinary single-file opening. It does not fabricate a list.
- Existing extraction landmarks follow the new `queueInstallationID` open
  parameter. The saved-preference and URL pause-restore negative controls still
  remove only their original condition, leaving the new queue condition intact.
- Legacy MPV lifecycle, loop-mode, menu, seek, HDR, playlist, silent-opening and
  clip fixtures declare their no-queue boundary explicitly. The real live MPV
  clip tests still execute the original seek and preview methods.
- Optional `NATIVE_ROUTE_BUILD_ONLY=1` compiles and checks source hashes without
  running playback. The normal route runner remains unchanged by default.

The changed directories are `ClipPreviewLiveTests`, `HDRColorStateTests`,
`NativeABLoopTests`, `NativeClipPreviewTests`, `NativePlaybackAdmissionTests`,
`NativePlayerCoreTests`, `NativePlayerRouteTests`, `NativeRotationHandoffTests`,
`PlaybackLifecycleTests`, `PlaybackMenuRoutingTests`, `PlaybackModeLiveTests`,
`PlaybackModeTests`, `PlaylistPlaybackTests`, `PlaylistPresentationTests`,
`SeekTimingTests`, `SilentVideoOpenTests`, `URLPlaylistEnqueueTests`, and
`VideoToolsTests`. New queue-specific and complete-App suites are owned separately.

## Executed regression evidence

These normal runs used the earlier queue candidate with Core SHA-256
`84f79683231266dcf59d402279b37420fb017ae12ce6ad7009c762d713b4196d`.
They are retained evidence for that candidate, not a claim about later changes.

| Command from the repository root | Result |
| --- | --- |
| `bash Tools/NativePlayerRouteTests/run.sh` | 335/0; `build/native-player-route-tests.uQDgvb` |
| `bash Tools/NativeClipPreviewTests/run.sh` | 235/0; `build/native-clip-preview-tests.VaI039` |
| `bash Tools/NativeABLoopTests/run.sh` | 151/0; `build/native-ab-loop-tests.7P27pA` |
| `bash Tools/NativeRotationHandoffTests/run.sh` | 176/0; four expected negative controls; `build/rotation-handoff-tests.jdgT86` |
| `bash Tools/URLPlaylistEnqueueTests/run.sh` | 118/0; eight expected negative controls; `build/url-enqueue-tests.ZkTiT2` |
| `bash Tools/NativePlaybackAdmissionTests/run.sh` | 64/0; preference negative control 64 checks/3 failures; `build/native-admission-tests.M7oLYY` |
| `python3 Tools/ClipPreviewLiveTests/run.py` | 324/0; 304 actual rendered frames; owned test App retired |

Also passed with the original assertions: controlled Core normal/ASan/TSan
41 checks and its two negative controls; lifecycle 76; seek timing 37; clip
navigation 317; playback menu 9 plus 22 guarded entries; native tools menu 151;
VideoTools English UI 942, coordinator 77 and task manager 132; legacy viewport
1098 per language; native viewport 172; HDR state 149; playback mode 126 and
cross-process persistence; live playback mode 58; playlist policy 3854 plus 51
live-MPV checks; presentation/controller and action groups in both languages;
silent video opening 363. These were local synthetic/owned-media tests.

After the shared explicit-plan and capture-B changes, Core SHA-256
`e12e14d5c20ecb7b163d5c93385a886e9167f9b6ce7b252f24fc6e119fdc145d`
passed controlled Core TSan 41 checks and both original negative controls.
`URL_ENQUEUE_SANITIZER=thread bash Tools/URLPlaylistEnqueueTests/run.sh` passed
118 checks; its eight controls failed by 27/9/7/2/3/4/2/2 as expected, with no
sanitizer diagnostic. `build/url-enqueue-tests.ML9ojv` retains logs and the
successful before/after source check. The queue model SHA-256 was
`81a1b73dd67d10255bd075ca06b5cdd2cc19139b28d684127578dbcdf9ca94c0`;
decoder SHA-256 was
`e3bcc18ecde84e48cf5556308eac7fc9802d6e5818ceecabe5b85e738b8958b9`.

## Failures and remaining verification

- `build/native-player-route-tests.cwl6nA` failed because the first new fixture
  incorrectly trapped even the production nil-queue publication. That fixture
  boundary was corrected; the failure remains retained and is not attributed
  to production playback.
- Final rotation TSan attempt `build/rotation-handoff-tests.qMRCcv` failed the
  original key-window precondition. Its positive and first negative logs contain
  no complete 176-check summary. It is not a valid positive or negative-control
  acceptance. Source verification passed; the original focus deadline remains.
- Final GUI reruns were stopped by the coordinator while preview/EOF intent
  interactions were being checked. Later production revisions require fresh
  same-source CI; earlier local passes must not be relabeled as that result.
- The pre-existing session TSan A/B timing failure and paused-seek nil-pixel
  failure remain independent unresolved evidence. This adaptation does not
  resolve them or establish complete-App queue behavior, physical-screen
  smoothness, audible synchronization, or target-M4 hardware decoding.

No files were staged or committed by this test owner; the coordinator owns the
ordered integration and subsequent CI/release decision.

## Cancelled-installation service adaptation

The coordinator subsequently added fail-fast declarations for
`prepareCancelledNativeQueueStop(owner:)` and `stopCancelledNativeQueue(owner:)`
to the four controlled MPV boundaries. These single-media fixtures must never
acknowledge a queue stop. The shared no-queue reset also requires no pending stop
owner. Lifecycle extraction now includes the actual installation-holder
declarations and compiles the real installer types.

The rotation/URL boundary declares a nil captured-preview baseline: those
single-media tests control preview completion and do not model queue intent.
The production pause/resume guards remain extracted unchanged; the real queue
preview contract is covered separately by `NativeCoreQueueTests`.

Before the final early-prepare call, Core SHA-256
`1e48890fffc5435ddd2837b247bbb293d05657f23787931556832197cc022cc1`
passed these new runs:

- Route: `build/native-player-route-tests.67jU2g`, 335/0.
- Rotation: `build/rotation-handoff-tests.23n4Py`, 176/0; four original controls
  failed by exactly 4/10/2/48, wrapper/source/generated checks all succeeded.
- URL TSan: `build/url-enqueue-tests.pczYE5`, 118/0; eight original controls
  failed by 27/9/7/2/3/4/2/2, wrapper and source checks succeeded.

The first rotation attempt `build/rotation-handoff-tests.nkjfIy` failed to compile
because its controlled boundary lacked `nativePreviewBaseline`. It executed no
assertions; its failure is retained, not labeled a production playback failure.

After adding the early-prepare call, final Core SHA-256
`98ff0c4cf304201eb481f40a14b80ff23d7a654a5d80986358a62272937714f7`
passed lifecycle 76 (x86_64 macOS 10.15 typecheck and ASan execution), controlled
Core TSan 41, and both original Core negative controls. The ordinary GUI runs
above remain tied to their earlier SHA, not relabeled as final-source acceptance.
No test App was created and no user preference or installed application changed.

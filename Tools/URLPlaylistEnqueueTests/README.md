# Native URL enqueue handoff regression

Run `bash Tools/URLPlaylistEnqueueTests/run.sh`. Set `URL_ENQUEUE_SANITIZER=address`
or `thread` for the same checks and negative controls under the sanitizer.
Each run retains its generated Swift, input hashes, logs and exit/source-check
results under an owned `build/url-enqueue-tests.*` directory.

`URL_ENQUEUE_BUILD_ONLY=1` compiles the positive fixture and all nine negative
variants without executing them. It verifies extraction/compilation only; it
does not count as passing behavior or successful negative-control rejection.

The fixture mechanically extracts production `PlayerCore` enqueue ownership,
compatibility capture/retirement, restore, navigation, pause/seek, stop/shutdown
and file-ended methods. It also compiles the actual AppDelegate enqueue/open
branch and completion closure; only the playlist read is replaced with a
controlled Boolean. The production final `sendOSD` main-queue closure is compiled
verbatim. Its earlier window/preference checks are outside this focused fixture.
The tests distinguish actual playlist notifications and `addToPlaylist` OSDs.

Capture, session shutdown, MPV load and append return codes use explicitly
controlled service boundaries shared with the rotation handoff tests. No user
media, preferences, installed applications, AppleEvents or GUI windows are used.
These checks prove arbitration and late-callback behavior, **not** complete-app
URL delivery, rendered playback, a real MPV append, or physical OSD rendering.

Coverage includes one transition for consecutive requests; capture/draining/
loading order; preserving volume/rate/A-B/viewport and latest pause/seek intent;
same-URL reopen, stop, shutdown, failure, timeout, delayed and repeated callbacks;
independent capture ownership after timeout; per-request/count/UTF8 bounds;
update admission; no append to an idle native compatibility core; failed and
missing MPV return callbacks; mixed URL-option rejection; the temporarily empty
playlist during handoff; notification reentry; final asynchronous OSD receipts;
and same-URL or different-URL subsequent MPV file-start events.

Eight single-variable negative controls restore an early append, missing reset
ownership, missing playback-restore ownership, ignored MPV status, the old empty
playlist branch, missing final OSD guard, stale tail receipts, or missing
file-start receipt invalidation. Every mutation must exit 1 with its named
failure; compilation failures, timeouts and sanitizer failures are not accepted
as successful negative controls. The positive run must retain every assertion.

The generic compatibility action scenario also needs the production file-start
media-generation increment and generic `.awaitingStart` to `.restoring` receipt
transition. These statements are mechanically extracted before the URL receipt;
the source URL remains supplied by the existing controlled load service. The
ninth `missing-generic-start` control removes only that generic receipt block
and must reproduce `Rejected enqueue preserves the existing compatibility action`.
This does not replace the generic state machine or claim real MPV event delivery.

CI `38361506765` on `35d99248` exposed the omitted generic receipt: both normal
and TSan positive variants reported 118 checks / 1 failure, despite step success.
The old compound `[[ child == expected && writer == 0 ]]` relied on `set -e`,
which macOS Bash 3.2 did not enforce. The runner now explicitly exits on any
child/writer status mismatch and records all three statuses. The existing
assertions and 20-second watchdog are unchanged.

`python3 -B Tools/URLPlaylistEnqueueTests/test_runner.py` extracts the actual
status gate and verifies nine normal/negative/writer/timeout/crash combinations
in `/bin/bash`. `--runner Tools/NativeRotationHandoffTests/run.sh` checks that
runner's actual gate too. `--negative-control` restores the old compound gate
and must fail seven combinations; this is a shell-only probe with no GUI.
The self-test is included in the runner input manifest and runs before compilation.

The original CI logs/artifacts are retained in
`build/native-ci-38361506765-final.nRD4ue`. Before fixing receipt extraction,
the explicit status gate reproduced 118 checks / 1 failure and correctly stopped
with exit 1 (`build/url-enqueue-tests.emJEJZ`). After extraction was corrected,
normal (`9q5VEW`), ASan (`umevIF`) and TSan (`umbESL`) each passed all 118 checks.
These suffixes identify `build/url-enqueue-tests.*` directories. Every original
negative's FAIL sequence matched the earlier `pczYE5` evidence exactly:
27/9/7/2/3/4/2/2 failures in the documented runner order. The new ninth control
had only its one expected failure. All negative children exited 1; log writers
exited 0. The three full runners exited 0 with matching, validated input
manifests (`3c512b135297611d45c8cf7ec5f548dd0755190245c7aed14760b5689964f7b6`).
Core input SHA-256 was
`14d8d1404bfc6483a2de39bfcaf353e0f10c01af90a73ce60ba6dc076415f0b1`.
Commands, wrapper statuses and the seven-failure legacy-shell negative probes
are retained in `build/url-enqueue-generic-receipt.Ze2iQ2`. Production code and
the original 118 assertions were not changed; this remains a controlled-service
fixture, not complete-App AppleEvent verification.

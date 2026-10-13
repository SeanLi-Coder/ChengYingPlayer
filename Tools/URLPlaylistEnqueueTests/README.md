# Native URL enqueue handoff regression

Run `bash Tools/URLPlaylistEnqueueTests/run.sh`. Set `URL_ENQUEUE_SANITIZER=address`
or `thread` for the same checks and negative controls under the sanitizer.
Each run retains its generated Swift, input hashes, logs and exit/source-check
results under an owned `build/url-enqueue-tests.*` directory.

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

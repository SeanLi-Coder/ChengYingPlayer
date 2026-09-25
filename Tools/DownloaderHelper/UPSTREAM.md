# Downloader engine provenance and integration boundary

The native downloader embeds the complete tracked source of `rednote_downloader`
version **1.2.23**, commit **e532e4fcd74bce4dfe730e49b8f1b49adceff62e**.
The original engine is licensed under MIT; its complete license and attribution
are preserved at `vendor/rednote/LICENSE`.

## Inventory

The 69 imported files include all application modules, the complete HTML/CSS/JS
interface, all upstream tests and smoke scripts, launchers and stop scripts,
dependency declarations, README, license, and `.gitignore`. Only `.github/`
workflow files are excluded: nested upstream CI is not part of the application.
No original configuration, cookies, browser profiles, job history, downloads,
virtual environment, Git history, or other untracked source files are included.

`upstream-manifest.json` schema 2 records both upstream and integrated SHA256 hashes
for every imported file. The original 69 upstream hashes are unchanged. Original
ChengYing additions are listed separately under `integration_files`, with their
own SHA256 and license, never with fabricated upstream provenance.
`verify_vendor.py` checks the complete inventory without
importing the engine or touching user data. Unlisted files, missing files,
symlinked sources, and unapproved modifications fail verification. Python bytecode
and pytest caches are ignored; they are not source or redistribution assets.

## Deliberate patches

Two optional environment variables in `app/main.py` move
writable files out of the signed, read-only application bundle:

- `CHENGYING_DOWNLOAD_DATA_DIR`: configuration and persisted task state.
- `CHENGYING_DOWNLOAD_DEFAULT_DIR`: the initial download destination when no
  saved configuration exists.

The native host must set both to absolute user-owned paths **before importing**
`app.main`. `PROJECT_ROOT`, static resources, build identity, and all downloader
behavior remain unchanged. Without these variables, the original `data/` and
`downloads/` defaults are preserved. A user's saved download-directory preference
continues to take precedence over the initial default.

The additive Kuaishou integration also patches `app/models.py`, `app/platforms.py`,
`app/downloader.py`, and `app/task_manager.py` to connect the new platform to the
existing queue, verified asset transfer, retry/cancel and state machinery.
`app/main.py` additionally redacts Kuaishou share-query values from public responses.
`app/static/app.js` and `app/static/index.html` add platform labels, localized
progress/errors and input guidance; original platform behavior is retained.
Each intentional change is explicitly allowlisted and hashed in the manifest.

Chrome Cookie failures are diagnosed by an additive patch to `app/browser.py`,
which classifies a read failure into one fixed, safe category: decryption,
permission, database lock, missing Chrome data directory, invalid or missing
profile, missing cookie database, or unknown. The probe never returns a profile
path, cookie value, token or raw exception text, and its own filesystem errors
fall back to the fixed `cookie_access_unknown` category instead of escaping and
masking the original `cookie_unavailable` business error. Cancellation and
interpreter-exit signals are deliberately not caught.

`app/douyin_signing.py` carries that category through the cookie-unavailable path
as a whitelisted structured code, so a local cookie failure is never relabelled
as a signing integrity failure or as a site response change. `app/models.py` adds
an optional diagnostic category field to the job and item records,
`app/task_manager.py` persists it with task state and recovers it for older
records, and `app/static/app.js` localizes each category with its own guidance
rather than collapsing every cookie failure into a single generic message. The
upstream English wording of the cookie error is preserved because unmodified
upstream tests assert it; only a fixed-code suffix and the structured field are
added. `tests/test_signing_diagnostics.py` covers the classification, the
helper's own error fallback, control-signal propagation and the chain end to end,
using synthetic exceptions, fictional profiles and temporary directories.

`app/kuaishou.py` is an original ChengYing extension, licensed GPL-3.0-or-later,
not part of the MIT upstream snapshot. It observes the site's normal Chrome
page responses and author-feed pagination. It does not copy third-party signing
code, replay private signed APIs, bypass challenges, or strip watermarks. Source
identity, author ownership, cursor continuity, trusted HTTPS hosts and redirect
targets are checked before accepting media. Incomplete profile enumeration is
reported as incomplete; recommendations are not substituted for requested media.
The adapter uses the existing native proxy hooks and does not persist temporary
media URLs. Its independent regression tests live in the helper's `tests/` folder.

### Kuaishou interruption, reporting and resume semantics

A rate-limited or transiently failing author-feed page no longer discards the
works already verified. Only `rate_limited`, `request_rejected`,
`site_unavailable` and `network_error` are treated as recoverable, and only while
a profile is actually being paginated. Login, verification, author/item identity
and security failures stay fatal and are never degraded into a partial result,
because doing so would hide a real access problem. `content_unavailable` is also
excluded: it describes one work, not a pagination interruption.

Recovery retries with a bounded backoff (3 attempts at 5s, 10s and 20s). Every
wait counts against the existing 300 second browser budget and is checked against
cancellation in 200ms slices, so cancellation stays immediate and one task can
never wait indefinitely. A retry resumes from the same expected cursor, which
preserves cursor continuity instead of restarting the walk or skipping pages.
When retries are exhausted the verified works are still returned as an
incomplete result carrying a fixed reason category. If nothing was verified at
all, the real error is raised; an interruption is never reported as an empty
profile, and a site-confirmed end (`pcursor == "no_more"`) is never implied.

Works that cannot be queued are reported with a bounded detail list (20 entries)
using fixed reason codes only: `no_verifiable_media`, `unsupported_media_type`,
`queue_limit_reached`, `page_item_limit_reached`. The user-facing summary counts
them and names up to ten affected works, stating explicitly when further entries
were only counted. Items beyond the protected page limit are counted rather than
silently dropped, but are not parsed, so an oversized page cannot cost unbounded
work. No site text, caption, cookie or media URL is ever included.

Completed assets are persisted per work under a single metadata key with a
`media_kind` of `video` or `image`, committed as soon as each asset passes its
checks and lands atomically. Records carry work identity, asset position and
local file facts only, never a URL or token, so they survive retries and
restarts. A saved asset is reused only after full re-verification: FFmpeg decode
plus declared-dimension checks for images, the FFprobe quality gate for videos.
A truncated, user-modified, moved or missing file is re-downloaded instead of
being trusted, and an existing user file is never overwritten.

Resume is delivered at four levels: in-session pagination continues from the
interrupted cursor; a retried or restarted task skips works already completed
and retries failed ones, keeping unmatched profile items queued while discovery
is incomplete; an album resumes per image; a single video resumes per file.
Two things are deliberately not implemented. Intra-file HTTP Range resume is not
done because Kuaishou media URLs are signed and expire, so splicing bytes fetched
under two different signatures could produce a corrupt file and would violate the
rule that a resumed task must not splice different content versions; an
interrupted file is cleaned up and re-downloaded whole instead. Pagination
cursors are not persisted across restarts either, because a cursor is opaque,
expiring site state and the site requires contiguous pagination from an empty
cursor, so a stale cursor would break the continuity guarantee.

The adapter must not use `run.py`'s project lock in the application bundle. Its
legacy `--runtime-dir` option only moves runtime records, not configuration,
task state, downloads, or the project lock. The native host owns process lifetime,
its private runtime directory, authenticated loopback transport, and shutdown.

## Preserved behavior

### Native proxy integration

The native adapter adds `proxy_config.py` and `proxy_transport.py` outside the
imported downloader source. Private `proxy.json` settings use
atomic writes and owner-only permissions, separate from upstream `config.json`
and task records. Authenticated `/api/native/proxy` endpoints expose only redacted
status. Saving a changed route takes the manager's submission lock and refuses
while any submitted job is unfinished, including queued work and cancellation
cleanup. Retrying a completed or cancelled task uses the newly saved route.

Only the helper process receives the transport hooks: both imported `YoutubeDL`
references, Playwright's newly launched headless browsers, and Douyin's separate
HTML `build_opener` path. The latter uses the already pinned yt-dlp `RequestsRH`,
preserving the caller's cookie jar, HTTP errors, cancellation checks, redirect
checks, body limit, and response lifetime. This avoids urllib's lack of full
SOCKS5 and HTTPS-proxy support. No new networking dependency or local forwarding
server is introduced. Both browser page requests and browser-context API requests
use the explicit route; existing user Chrome sessions and system settings are
not modified. Existing HTTP Range/retry and media validation logic is retained.

Supported routes are HTTP, TLS-authenticated HTTPS proxies, and unauthenticated
SOCKS5 with remote destination DNS. HTTP(S) credentials use ASCII to avoid differing
browser and media-client authentication encodings. User information is separated into
the browser's authentication fields and redacted from diagnostics. Chrome does
not support authenticated SOCKS5; such settings are rejected before saving.
Disabled proxy settings mean explicit direct mode, even if the parent process
has proxy environment variables. An invalid saved file blocks network entry
points until explicitly cleared or repaired; a failed proxy never falls back to
direct mode. HTTPS certificate verification remains enabled.

`tests/test_proxy_config.py` covers protected APIs and persistence, and
`tests/test_proxy_transport.py` exercises local HTTP/SOCKS5/TLS proxy fixtures.
When Google Chrome is installed it also tests real headless browser requests,
without visiting public sites or loading user profiles. The isolated frontend
suite is `node Tools/DownloaderProxyUITests/main.mjs`; native WebKit coverage is
included in `bash Tools/DownloadCenterTests/run.sh`.

### Original engine guarantees

The original engine retains Xiaohongshu, Douyin, Bilibili, and YouTube discovery/downloads;
author and item identity validation; original-quality selection and FFprobe
verification; video/audio remuxing; photos and live photos; Chrome profile and
login verification; per-task and per-item retry/cancel; persisted job recovery
and migrations; serialized state updates; sensitive-field redaction; and live
SSE progress. Native integration must call the same API rather than recreate a
reduced downloader or bypass the upstream permission and validation gates.

Google Chrome remains required for the upstream Playwright `channel="chrome"`
and login flows. The native WKWebView hosts only the local application UI; it is
not a substitute for Chrome's cookie/profile/runtime integration. The managed
runtime also needs the pinned yt-dlp distribution, Deno, Playwright's driver,
FFmpeg, FFprobe, and their applicable third-party notices. Do not bundle user
Chrome profiles or cookie exports.

## Verification

Run the following with the managed helper Python or a Python environment with
the upstream dependencies installed:

```sh
python Tools/DownloaderHelper/verify_vendor.py
python -m unittest discover -s Tools/DownloaderHelper/tests -p test_vendor.py -v
python Tools/DownloaderHelper/run_upstream_tests.py
```

The path-isolation tests import only a temporary copy of the engine and verify
both native writable paths and unchanged upstream defaults. Never run import-time
engine tests against a real user's original source checkout or data directory.
The upstream runner copies only manifest-listed files, clears inherited native
runtime paths, and blocks non-loopback TCP/UDP and external DNS in the pytest
process and its Python subprocesses. A temporary, opt-in `sitecustomize.py` guard
preserves each fixture's package paths while making loopback forward and reverse
DNS independent of the system resolver. It is never installed in the application
or the user's Python environment. Its subprocess lifecycle tests create their own local services; real
network smoke scripts are not part of this offline run. Additional pytest
arguments can follow `--`, for example `-- -k test_stop`.

The pristine upstream offline baseline on 2026-09-17 was **1379 passed, 1 failed**
(Python 3.11). The pre-existing failure in
`tests/test_stop.py::test_no_record_and_no_legacy_listener_is_idempotent` came from
an unmocked health request to the machine's occupied localhost port 8766. That
test now mocks the absent server instead of consulting unrelated user processes.
A separate test covers a legacy listener disappearing before inspection.
Production `stop.py` and its strict refusal to signal unverified processes are
unchanged. The native adapter must use its authenticated owned process lifecycle,
not legacy listener discovery or global process termination.

`tests/test_stop.py` and `tests/test_signing_diagnostics.py` are the two modified
upstream test-source files; both changes are allowlisted and hashed in the
manifest, and no other upstream test file is modified. The signing diagnostics
file only gains additive tests for the Chrome Cookie diagnostic categories
described above. Upstream hashes are preserved for both files, so the original
sources remain verifiable.

After the isolated-test correction, the complete vendored suite passed:
**1381 passed in 65.23 seconds**. It ran from a temporary source copy with
non-loopback socket connections blocked in the pytest process. The seven
additional vendoring and writable-path isolation checks also passed. The engine
tests use synthetic browser-cookie databases and mocked browser launches; real
network smoke scripts are preserved but were not executed during this check.

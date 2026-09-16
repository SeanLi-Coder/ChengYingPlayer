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

`upstream-manifest.json` records both upstream and integrated SHA256 hashes for
every imported file. `verify_vendor.py` checks the complete inventory without
importing the engine or touching user data. Unlisted files, missing files,
symlinked sources, and unapproved modifications fail verification. Python bytecode
and pytest caches are ignored; they are not source or redistribution assets.

## Deliberate patch

Only `app/main.py` differs in production code. Two optional environment variables move
writable files out of the signed, read-only application bundle:

- `CHENGYING_DOWNLOAD_DATA_DIR`: configuration and persisted task state.
- `CHENGYING_DOWNLOAD_DEFAULT_DIR`: the initial download destination when no
  saved configuration exists.

The native host must set both to absolute user-owned paths **before importing**
`app.main`. `PROJECT_ROOT`, static resources, build identity, and all downloader
behavior remain unchanged. Without these variables, the original `data/` and
`downloads/` defaults are preserved. A user's saved download-directory preference
continues to take precedence over the initial default.

The adapter must not use `run.py`'s project lock in the application bundle. Its
legacy `--runtime-dir` option only moves runtime records, not configuration,
task state, downloads, or the project lock. The native host owns process lifetime,
its private runtime directory, authenticated loopback transport, and shutdown.

## Preserved behavior

### Native proxy integration

The native adapter adds `proxy_config.py` and `proxy_transport.py` without changing
the imported downloader source or its manifest. Private `proxy.json` settings use
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
A separate test covers a legacy listener disappearing before inspection. These
are the only test-source changes; production `stop.py` and its strict refusal to
signal unverified processes are unchanged. The native adapter must use its
authenticated owned process lifecycle, not legacy listener discovery or global
process termination.

After the isolated-test correction, the complete vendored suite passed:
**1381 passed in 65.23 seconds**. It ran from a temporary source copy with
non-loopback socket connections blocked in the pytest process. The seven
additional vendoring and writable-path isolation checks also passed. The engine
tests use synthetic browser-cookie databases and mocked browser launches; real
network smoke scripts are preserved but were not executed during this check.

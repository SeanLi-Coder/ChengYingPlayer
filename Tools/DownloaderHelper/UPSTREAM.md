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

### 原生专用登录边界（2026-10-09）

`login_sessions.py` 管理独立 Chrome 窗口，只用播放器数据目录中的专用 `user_data_dir`，
不读取日常 Chrome、Local State 或钥匙串，也不自动授予文件访问权限。用户显式打开、手动登录、
显式保存；网站挑战仍由用户处理。`login-policy.json` 默认为 `dedicated`，另可明确选择
`chrome` 或 `anonymous`；旧 config、任务、输出目录均不迁移。

`login-sessions/<platform>/chrome` 与 owner-only 的不可变快照放在 App 外，升级不改路径。
快照仅含该平台允许域的非分区 Cookie，保存和每次读取均检查本地认证 Cookie 的名称、域、根路径及有效期；
这些启发式不能证明服务器仍认可登录，网站认证格式变化也可能需要更新适配。旧任务固定旧修订，
重新登录后需新建任务，不静默换号。快照标识不会进入公开任务响应，Cookie 不进入 API、日志或诊断。

`login_auth.py` 在 native helper 内统一接管 pinned yt-dlp 底层 Cookie extractor 及 XHS 的
资料预检；专用任务禁止匿名降级，拒绝平台与修订不匹配。专用 CookieJar 经 yt-dlp 合并及 requests
请求准备／重定向后仍保留 host-only 约束。`summary_source.py` 使用相同模式与快照，
但仅包装自身传输实例，不加载真实 `app.main` 状态。旧 Chrome 模式的提取策略不变。

主机 API 仍经过原有认证、同源与版本屏障。专用窗口整个生命周期计入更新和代理忙碌状态，
代理保存后才打开窗口，失败不回退直连；关闭未确认时保持忙碌，不宣称成功退出。
helper 在关闭失败时保留现有父进程控制的退出 watchdog，不使用全局 Chrome 清理或 TCC 操作。

`browser.py` 仅新增固定专用登录诊断及提前返回，避免错误诊断再次扫描日常 Chrome；
`main.py` 隐去专用快照标识；`static/app.js` 提供相应指引。这三处新增补丁均记录精确散列。
原始 standalone 行为和上游哈希不变，不把这些原生新增模块冒充上游源码。

离线验证使用私有临时数据、合成 Cookie、真实隔离 Chrome 及原生 WKWebView 的回环页面。
`login_smoke.py` 还验证实际冻结运行时的不可变快照／重启。Google 可能拒绝自动化窗口登录；
没有真实账号验收时不得声称所有平台登录或下载已成功。

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

The additive Instagram integration patches that same set of files, plus
`app/static/styles.css`: `app/models.py` gains an `INSTAGRAM` platform value
without changing an existing one; `app/platforms.py` recognizes strictly validated
profile and post URLs and rejects explore, stories, hashtag, account and
share-tracking surfaces; `app/downloader.py` adds discovery and per-part download
dispatch on the existing verified transfer, proxy, progress and cancellation
machinery; `app/task_manager.py` keeps an incomplete profile discovery retryable;
`app/main.py` redacts Instagram share tracking tokens; and `app/static/app.js` with
`app/static/index.html` add the platform label, localized progress/errors and input
guidance. `app/static/styles.css` supplies the platform dot colors the interface
already referenced, so a dot renders in its platform color rather than the
inherited text color.

Chrome Cookie failures are diagnosed by an additive patch to `app/browser.py`,
which classifies a read failure into one fixed, safe category: decryption,
permission, database lock, missing Chrome data directory, invalid or missing
profile, missing cookie database, invalid database, storage I/O/resource failure,
reader dependency/interface failure, or unknown. The probe never returns a profile
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

The Chrome Cookie adapter now accepts yt-dlp's `only_once` / `once` warning
arguments and retains only whitelisted failure categories, never the warning
text. Both `app/douyin_signing.py` and the intentionally patched `app/douyin.py`
browser fallback use it. An unavailable site session after a decryption warning
remains a Cookie failure rather than silently becoming anonymous discovery;
cancellation propagates unchanged. Unspecified profiles are no longer diagnosed
as if the extractor always chose `Default`.
The generic yt-dlp failure path in `app/downloader.py` also preserves these fixed
diagnostics for single videos, without changing explicitly enabled anonymous
fallback or cancellation behavior.

The settings interface exposes the existing `chrome_profile` setting. Saving a
profile affects new tasks only, preserves the independent downloader's original
state boundary, and never switches an existing task's identity. New profile
choices accept Chrome directory names, not arbitrary paths. Decryption guidance
does not assert that macOS denied authorization when the cause is unknown.

`cookie_smoke.py` adds actual AES and pinned yt-dlp extraction to the frozen
helper's offline self-test, using only a generated SQLite database and a mocked
keychain process. It covers usable cookies, an unrelated corrupt cookie and an
unavailable key. It never reads a real profile, calls the real keychain, or emits
fixture values. Additional helper-level tests cover these boundaries and the
real settings handlers; preserved upstream tests remain intact.

### Native profile inventory and submission preflight

`chrome_profiles.py` enumerates only standard Chrome directory names and checks
directory/database metadata. It never opens cookie contents, Local State or the
keychain, and it does not infer an account from a directory name. Scans are
bounded, reject symlinked entries and distinguish unavailable inventory from a
confirmed missing profile. The authenticated native profile API exposes names
and fixed status codes, not paths or account identifiers.

The native host replaces the example-only profile input with actual local choices.
Explicit invalid or missing profiles require the user to select and save a valid
choice before creating a task. Saving and submission preflight share the original
configuration lock, so a concurrent settings update cannot change the checked
identity. Unchanged legacy settings survive unrelated edits; previous tasks keep
their original identity when retried. Automatic selection and saved cookie-off
mode retain upstream semantics. No account is silently substituted.

`profile_smoke.py` runs the shipped inventory and validation code against private
synthetic directories in frozen self-tests. Browser regressions exercise the real
UI with loopback fixtures and an isolated Chrome context, never a real profile.

### Native Chrome-cookie consistency and malformed-record handling

`chrome_cookie_runtime.py` installs immutable, process-local adapters for the
pinned yt-dlp before the native service accepts requests. The database adapter
uses a bounded SQLite online backup from a read-only source connection rather
than copying only the main database file. This includes committed WAL records
and deletions. It does not checkpoint the browser database, change profiles,
or fall back to an older main-file snapshot. SQLite can create/use its standard
WAL coordination sidecars; the source main database and existing WAL bytes are
not rewritten. Each snapshot is private, uniquely named and owner-only, and is
removed when extraction completes or fails.

The row adapter skips only recognized malformed macOS AES-CBC lengths or invalid
UTF-8 data, emitting a fixed warning with no cookie bytes. Unexpected dependency,
programming and control-flow errors are not swallowed. A task-local context
carries cancellation and the requested site's authentication requirements;
concurrent tasks cannot inherit another task's guard or profile. Douyin signing,
browser fallback and generic yt-dlp extraction all check the same returned jar:
after an extraction warning, a still-valid session covering the requested site
is required. Non-authentication cookies do not justify silent anonymous access.
Explicit cookie-off and explicitly enabled anonymous fallback retain their
existing meaning. Exception chains preserve cancellation even when yt-dlp wraps
it in a generic download error.

Offline tests use real synthetic SQLite/WAL data and the pinned extractor with a
fake keychain. Frozen self-tests cover new tables/updates/deletions committed in
WAL, unrelated malformed rows, unusable target credentials and the actual
`YoutubeDL.cookiejar` path. Passing these tests is not evidence of a successful
download with a user's real Chrome account or of the exact cause on another Mac.

### Opt-in diagnostic report export

The native host adds an authenticated read-only `/api/native/diagnostics` endpoint
and a separate diagnostic panel; the preserved engine UI and task persistence
schema remain unchanged. The panel loads a report only when the user opens it,
allows preview and explicit clipboard copying, and never uploads a report.
Clipboard restrictions fall back to selected text and manual Command+C.

`diagnostic_log.py` records a bounded in-memory timeline for this helper process.
Both capture and export apply fixed allowlists: stage, status, issue category,
numeric error codes, known exception types and trusted module/line locations.
It never formats exception messages, stack source text, locals, cookie values,
profile names, URLs, output paths or task titles. Reports contain at most ten
anonymous tasks and 64 KiB of text. Older stored task states are distinguished
from events observed in this process; their original application version is
unknown, not inferred from the current build. Logs are not persisted across app
restarts, and collection does not read Chrome, the keychain or unrelated files.

`diagnostic_identity.py` creates a sealed build resource with the player version,
build number and a source fingerprint of the native helper and static assets.
These are separate from the original downloader engine's version and build ID.
Frozen self-tests execute a synthetic capture/export privacy check and require
the bundled identity; no real browser data or clipboard is accessed.

### Cancellable FFprobe input delivery

`app/downloader.py` supplies bounded in-memory media prefixes through a temporary
input file instead of retrying `communicate(input=...)` after a timeout. On Python
3.13, retrying with `input=None` can stop scheduling the remaining pipe writes,
turning a short process-start delay into a media-probe timeout. FFprobe still uses
the existing `pipe:0` protocol and unchanged total deadline and cancellation poll.
The input file is anonymous on macOS and closed with the child output on every
exit; local I/O failures use a fixed public error rather than exposing a path.
Only this imported implementation hash changes, not the original upstream hash.
Synthetic child-process regressions cover delayed reads, full input delivery,
empty input, cancellation, real deadlines and cleanup without browser access.

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

Starting with the post-v0.2.38 review, completion receipts also include a SHA-256
digest of the local bytes and a SHA-256 fingerprint of the complete trusted source
candidate set, including signed query strings. Raw candidate URLs are never
persisted. File hashing uses bounded chunks, cancellation checks, and file-state
checks around verification. A same-size replacement, a reordered image with a
different source, or a receipt missing these hashes cannot be silently reused.
Video reuse checks the actual matching highest-quality candidate, not only the
first codec variant. Incremental album updates preserve valid receipts for later
members that have not yet been retried.

Source equality does not prove that a remote object has never changed. This is a
conservative reuse rule: changed signatures or candidate sets can cause a fresh
download even when the visual content is unchanged. Legacy receipts without hash
evidence are preserved but not trusted for reuse; existing files are not replaced.
The interface distinguishes bounded retries within the current browser session
from a user-initiated retry, which rediscovers the profile with fresh cursors.

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

### Instagram profile enumeration, interruption and resume semantics

`app/instagram.py` is an original ChengYing extension, licensed GPL-3.0-or-later,
not part of the MIT upstream snapshot. It observes the paginated GraphQL profile
timeline that Instagram's own page JavaScript produces while the page is scrolled.
It does not copy third-party signing code, replay private signed APIs, bypass
challenges, or strip watermarks. Author and post identity, trusted HTTPS media
hosts and redirect targets are checked before accepting media. Its independent
regression tests live in the helper's `tests/` folder.

Requests are allowed natively rather than relayed. Fetching each request inside
the route handler and fulfilling the route with that copy stalls this page:
measured against a real logged-in profile through the production discovery path,
loading stopped at 67 responses and never advanced through 20 further scrolls,
the profile component never mounted, so the site never issued its timeline query
and discovery reported no verified posts for an author with 442. Three controls
separate the cause: registering a handler that calls `continue_()` for every
request loaded 353 responses and produced the timeline query; no handler at all
loaded 345 and produced it; every relay variant produced none. Keeping the
original cookie header, stripping `content-encoding` on fulfill and not aborting
media all failed identically, so the relay itself is the cause, not a missing
header or a blocked subresource. Kuaishou tolerates the same relay because its
page is far lighter.

The redirect guarantee the relay existed to provide is kept, and strengthened.
`continue_()` does not re-enter the route handler for each hop, so a request
listener re-applies the trusted-host allowlist to every request Chromium actually
issues, measured at 295 of 295 on a real profile with zero off-host redirects.
A `framenavigated` listener records the URL the main frame committed to, which the
existing identity check verifies; that observes the final rendered location
instead of each requested hop. Blocking media, image and font subresources is
retained and measured harmless: it skipped 110 image requests while the timeline
query was still issued, and it keeps the browser budget for pagination.

Completion is claimed only on site-confirmed evidence. `page_info.has_next_page`
observed as false is the only site-confirmed end of list. The same response set
carries `data.user.media_count`, the author's own declared post total, so a walk
that stops short of it is reported incomplete with the missing count rather than
being silently presented as finished. Works are accumulated as each response
arrives, because a profile renders a virtual list whose DOM only ever holds a
sliding window of links; reading links back at the end would lose most of them.

Media kind is resolved deliberately. Images are taken from the page's own
`image_versions2` candidates, which do declare exact dimensions, and a candidate
without its own width and height can never be claimed as the highest quality.
Videos are left to the existing media pipeline: a post's own `video_versions`
top out below the rendition that pipeline resolves, so pinning the in-page
address would silently downgrade quality. A single post is not resolved by page
scraping either, because Instagram serves no observable per-post JSON response
and a rendered post page mixes the requested post with home-feed
recommendations. Only `p/<shortcode>` and the deprecated `<post>/media/` suffix
identify one post; a deeper path is a different surface and is rejected, so an
unrelated post whose first segment merely looks like a shortcode is never
downloaded.

A rate-limited or transiently failing profile page no longer discards the works
already verified. Only `rate_limited`, `request_rejected`, `site_unavailable` and
`network_error` are treated as recoverable, and only while a profile is actually
being paginated. Login, verification, author/post identity and security failures
stay fatal and are never degraded into a partial result, because doing so would
hide a real access problem. `content_unavailable` is also excluded: it describes
one post, not a pagination interruption.

Recovery retries with a bounded exponential backoff (3 attempts at 5s, 10s and
20s). Every wait counts against the existing 300 second browser budget and is
checked against cancellation in 200ms slices, so cancellation stays immediate and
one task can never wait indefinitely. A retry resumes from the same expected
cursor, which preserves cursor continuity instead of restarting the walk or
skipping pages. When retries are exhausted the verified works are still returned
as an incomplete result carrying a fixed reason category. If nothing was verified
at all, the real error is raised; an interruption is never reported as an empty
profile.

Cancellation takes priority over an empty result. A cancelled walk yields no
items, so the dispatcher re-checks cancellation before concluding that the site
returned no verified media; the user's own stop is never reported to them as a
site problem that sends them to look for content they cancelled.

Posts that cannot be queued are reported with a bounded detail list (20 entries)
using fixed reason codes only: `no_verifiable_media`, `unsupported_media_type`,
`not_this_author`, `queue_limit_reached`, `page_item_limit_reached`. The
user-facing summary counts them and names up to ten affected shortcodes through a
fixed label map, stating explicitly when further entries were only counted. No
caption, media URL, cookie or account detail is ever included.

A media address carries an expiring signature, so none is persisted. Each part is
resolved again at download time, and a retry rediscovers the profile with fresh
cursors. Only the post shortcode and its position inside a carousel are stored,
so every carousel member can be retried or resumed on its own.

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

### Native author-only download layout

The native helper opts new tasks into `OutputLayout.AUTHOR` before accepting API
requests. A selected root such as `~/app/data` produces `~/app/data/ABC` for author
`ABC`, without an application or platform parent. Fresh native installations use
`~/Downloads` as their initial root. Explicit saved roots are not rewritten, even
if their final component is named `ChengYing` or `Kuaishou`.

The task persists its layout alongside its root. Missing layout fields retain
the legacy `PLATFORM_AUTHOR` policy; the independent engine keeps that default.
Native retries, rediscovery and recovery keep an existing task's output directory,
including when an author changes their display name. No old media is moved and
no historical receipt is rebound to a newly computed directory. Author names
remain sanitized direct children; an unknown native author uses `Unknown Author`.
Existing author symlinks and conflicting regular files are rejected.

Because different platforms can now share an author directory, new native tasks
also opt into no-overwrite publication. Direct transfers and verified probe files
are committed without replacing an existing target. Generic yt-dlp transfers
finish in their existing task-private staging directory before publication.
Collisions receive numbered filename suffixes within the UTF-8 component limit.
On macOS, `renamex_np(RENAME_EXCL)` provides atomic exclusive publication; if a
volume cannot support the operation, publication fails rather than overwriting.
The non-macOS test/engine path uses exclusive hard-link publication. This does
not transcode media or relax source identity, quality, receipt, proxy or login
checks. Legacy tasks retain their original transfer policy.

Regression coverage is in `tests/test_author_output_layout.py`,
`tests/test_author_output_collisions.py`, `tests/test_native_config.py`, and the
native `Tools/DownloadCenterTests` fixture. Fixtures use temporary directories,
synthetic media and local/mocked transport, not real accounts or private media.

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

### Unicode filename and local-directory compatibility

`app/downloader.py::safe_component` additionally replaces unassigned,
noncharacter and surrogate code points before UTF-8 encoding. It bounds runs of
nonzero canonical combining classes to 31 in NFD, then recomposes NFC. Existing
NFKC compatibility normalization, illegal-character replacement, byte limits and
reserved-name handling remain. Ordinary Chinese text, accents, private-use text,
emoji joiners and zero-combining-class marks retain their existing meaning.
The same sanitizer protects author folders and media filename components.

`app/task_manager.py` classifies directory-preparation failures as local
configuration errors, preserving the underlying exception cause without exposing
its path. Existing saved task directories are not renamed or migrated, and the
native no-overwrite publication policy still handles sanitized-name collisions.
`app/static/app.js` gives these failures dedicated local-folder guidance, including
legacy stored messages, instead of advising Chrome login or component reinstall.

The instance-only native diagnostic adapter captures handled exceptions through
`_record_issue_locked`. It records only the existing bounded type/code/frame
allowlists, including numeric filesystem errno, never raw messages, author names,
paths, cookies or URLs. `filename_smoke.py` verifies synthetic Unicode directory
and media names in the actual frozen self-test. Offline regressions cover native
and legacy layouts, normalization boundaries, error causes and private reporting;
real-site downloads are a separate explicitly authorized verification.

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

The isolated runner also supplies a per-test temporary Chrome diagnostic root,
so generic error-classification tests cannot probe the developer's Chrome
directories. Explicit browser fixtures remain free to supply their own temporary
roots. The runner does not replace HOME or change production runtime settings.

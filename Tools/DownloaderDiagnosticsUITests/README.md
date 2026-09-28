# Diagnostic panel tests

Run `node Tools/DownloaderDiagnosticsUITests/main.mjs` from the repository root.

The suite executes the complete production `static/diagnostics.js` in an isolated
DOM fixture. HTTP responses, timers, and both clipboard methods are synthetic;
the tests never read browser profiles, contact a server, write the real clipboard,
or create output files.

Coverage includes explicit report loading and copying, recent-task scope,
authentication/cache request options, duplicate clicks, strict schema/type/UTF-8
size checks, bounded streaming responses, fixed error messages, timeouts, stale
responses, page closure, version mismatch, selection fallback, and manual-copy
guidance. Real WKWebView integration lives in `Tools/DownloadCenterTests`.

The host should inject `/native/diagnostics.css` and a deferred
`/native/diagnostics.js` on its authenticated index page. The script owns the
`desktop-diagnostics-*` element IDs and requests only
`GET /api/native/diagnostics`, without a `job_id`, because the original frontend
does not expose a reliable selected-task identifier. The response contract is
`{ "schema_version": 1, "text": "English diagnostic report" }`, with at most
64 KiB of UTF-8 report text. The JSON transport envelope is independently capped
at 512 KiB to accommodate escaped characters.

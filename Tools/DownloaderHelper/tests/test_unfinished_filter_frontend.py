"""Exercise independent history/item filters with synthetic state and isolated Chrome."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from playwright.sync_api import expect, sync_playwright

STATIC = Path(__file__).resolve().parents[1] / "vendor/rednote/app/static"
CHROME = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
MARKER = "  initialize();\n})();\n"
EXPORT = """  window.filterTest = {
    isUnfinishedJob, isUnfinishedItem, state, upsertJob, renderSelectedJob,
    renderHistory, handleEvent, bindEvents
  };
})();
"""
ITEM_STATUSES = [
    "queued", "downloading", "postprocessing", "needs_auth", "completed", "failed",
    "cancelled", "skipped", "partial", "interrupted", "retrying", "unknown",
]
JOB_STATUSES = [
    "queued", "discovering", "downloading", "needs_auth", "completed", "partial",
    "failed", "cancelled", "interrupted", "retrying", "unknown",
]


def ui_source():
    source = (STATIC / "app.js").read_text(encoding="utf-8")
    assert source.count(MARKER) == 1
    return source.replace(MARKER, EXPORT)


def node_result(body):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is unavailable")
    script = (
        "globalThis.window = {}; globalThis.document = {querySelector: () => null};\n"
        + ui_source()
        + "\n" + body
    )
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def predicate_results(method, cases):
    return node_result(
        f"const cases = {json.dumps(cases)};\n"
        + f"process.stdout.write(JSON.stringify(cases.map(window.filterTest.{method})));"
    )


@pytest.mark.parametrize("item_status", ["completed", "failed", "skipped"])
def test_repeated_snapshot_classification_does_not_reread_items(item_status):
    result = node_result("""
      let itemsReads = 0;
      let statusReads = 0;
      const items = Array.from({length: 128}, () => Object.defineProperty({}, 'status', {
        get() { statusReads += 1; return ITEM_STATUS; }
      }));
      const snapshot = Object.defineProperty({status: 'completed', discovery_complete: true}, 'items', {
        get() { itemsReads += 1; return items; }
      });
      const first = window.filterTest.isUnfinishedJob(snapshot);
      const initialReads = {itemsReads, statusReads};
      const repeated = Array.from({length: 100}, () => window.filterTest.isUnfinishedJob(snapshot));
      process.stdout.write(JSON.stringify({first, repeated, initialReads, finalReads: {itemsReads, statusReads}}));
    """.replace("ITEM_STATUS", json.dumps(item_status)))
    expected = item_status != "completed"
    assert result["first"] is expected
    assert result["repeated"] == [expected] * 100
    assert result["initialReads"]["itemsReads"] > 0
    assert result["initialReads"]["statusReads"] > 0
    assert result["finalReads"] == result["initialReads"]


@pytest.mark.parametrize("changes", [
    {"discovery_complete": False},
    {"failed_items": 1},
    {"total_items": 2},
    {"items": [{"status": "failed"}]},
    {"items": [{"status": "skipped"}]},
])
def test_new_upsert_snapshot_reclassifies_same_status_without_poisoning_old_cache(changes):
    result = node_result("""
      const api = window.filterTest;
      const base = {id: 'cache-test', status: 'completed', discovery_complete: true,
        total_items: 1, completed_items: 1, failed_items: 0, items: [{status: 'completed'}]};
      const first = api.upsertJob({...base, revision: 1});
      const initial = api.isUnfinishedJob(first);
      const changed = api.upsertJob({id: 'cache-test', status: 'completed', revision: 2, ...CHANGES});
      const updated = api.isUnfinishedJob(changed);
      const restored = api.upsertJob({...base, revision: 3});
      process.stdout.write(JSON.stringify({
        distinct: first !== changed && changed !== restored,
        sameStatus: first.status === changed.status && changed.status === restored.status,
        initial, updated, recovered: api.isUnfinishedJob(restored),
        oldInitial: api.isUnfinishedJob(first), oldChanged: api.isUnfinishedJob(changed),
        storedCurrent: api.state.jobs.get('cache-test') === restored
      }));
    """.replace("CHANGES", json.dumps(changes)))
    assert result == {
        "distinct": True, "sameStatus": True, "initial": False, "updated": True,
        "recovered": False, "oldInitial": False, "oldChanged": True, "storedCurrent": True,
    }


def test_cache_is_snapshot_scoped_not_id_or_revision_scoped():
    result = node_result("""
      const api = window.filterTest;
      const original = api.upsertJob({id: 'same-version', revision: 7, status: 'completed',
        items: [{status: 'completed'}], discovery_complete: true});
      const initial = api.isUnfinishedJob(original);
      const equalRevision = api.upsertJob({id: 'same-version', revision: 7, items: [{status: 'failed'}]});
      const equalResult = api.isUnfinishedJob(equalRevision);
      const legacy = api.upsertJob({id: 'legacy', status: 'completed', items: [{status: 'completed'}]});
      const legacyInitial = api.isUnfinishedJob(legacy);
      const legacyChanged = api.upsertJob({id: 'legacy', items: [{status: 'queued'}]});
      const legacyResult = api.isUnfinishedJob(legacyChanged);
      const stale = api.upsertJob({id: 'same-version', revision: 6, items: [{status: 'completed'}]});
      process.stdout.write(JSON.stringify({initial, equalResult, legacyInitial, legacyResult,
        ignoredStale: stale === equalRevision, staleResult: api.isUnfinishedJob(stale)}));
    """)
    assert result == {
        "initial": False, "equalResult": True, "legacyInitial": False, "legacyResult": True,
        "ignoredStale": True, "staleResult": True,
    }


def test_all_job_states_and_legacy_completion_aliases_have_explicit_semantics():
    cases = [{"status": status} for status in JOB_STATUSES]
    expected = [status != "completed" for status in JOB_STATUSES]
    aliases = ["complete", "done", "downloaded", "success", "succeeded", " COMPLETED "]
    cases += [{"status": status} for status in aliases] + [{}, {"state": "failed"}]
    expected += [False] * len(aliases) + [True, True]
    assert predicate_results("isUnfinishedJob", cases) == expected


def test_all_item_states_include_skipped_unknown_and_partial_but_not_success_aliases():
    cases = [{"status": status, "retryable": False} for status in ITEM_STATUSES]
    expected = [status != "completed" for status in ITEM_STATUSES]
    aliases = ["complete", "done", "downloaded", "success", "succeeded", " COMPLETED "]
    cases += [{"status": status} for status in aliases] + [{}, {"state": "cancelled"}]
    expected += [False] * len(aliases) + [True, True]
    assert predicate_results("isUnfinishedItem", cases) == expected


@pytest.mark.parametrize("changes", [
    {"discovery_complete": False},
    {"cancel_requested": True},
    {"failed_items": 1},
    {"active_count": 1},
    {"total_items": 4, "completed_items": 3},
    {"stats": {"total": 4, "success": 3}},
    {"statistics": {"failed": 1}},
    {"items": [{"status": "failed", "retryable": False}]},
    {"items": [{"status": "cancelled"}]},
    {"items": [{"status": "skipped", "retryable": False}]},
    {"items": [{"status": "queued"}], "completed_items": 1, "total_items": 1},
    {"items": [{"status": "postprocessing"}]},
    {"items": [{"status": "needs_auth"}]},
])
def test_completed_label_does_not_hide_incomplete_discovery_or_work(changes):
    job = {"status": "completed", "discovery_complete": True, **changes}
    assert predicate_results("isUnfinishedJob", [job]) == [True]


def test_verified_completion_and_old_records_without_optional_counters_are_not_unfinished():
    cases = [
        {"status": "completed"},
        {"status": "completed", "items": []},
        {"status": "completed", "discovery_complete": True, "failed_items": 0,
         "completed_items": 2, "total_items": 2, "items": [{"status": "completed"}] * 2},
        {"status": "completed", "discovery_complete": True, "cancel_requested": False,
         "stats": {"total": 1, "success": 1, "failed": 0, "active": 0}},
    ]
    assert predicate_results("isUnfinishedJob", cases) == [False] * len(cases)


@pytest.fixture(scope="module")
def browser():
    if not CHROME.is_file():
        if os.environ.get("CHENGYING_REQUIRE_CHROME_UI") == "1":
            pytest.fail("The required real Chrome UI runtime is not installed")
        pytest.skip("The optional real Chrome UI runtime is not installed")
    with sync_playwright() as playwright:
        instance = playwright.chromium.launch(
            channel="chrome", headless=True, args=["--no-proxy-server"], timeout=15000,
        )
        try:
            yield instance
        finally:
            instance.close()


@pytest.fixture
def page(browser):
    context = browser.new_context(service_workers="block", viewport={"width": 1200, "height": 1000})
    unexpected_requests = []
    errors = []

    def deny_request(route):
        unexpected_requests.append("unexpected request")
        route.abort()

    context.route("**/*", deny_request)
    tab = context.new_page()
    tab.set_default_timeout(5000)
    tab.on("pageerror", lambda error: errors.append(type(error).__name__))
    html = (STATIC / "index.html").read_text(encoding="utf-8")
    html = re.sub(r"<script\b[^>]*>.*?</script>", "", html, flags=re.DOTALL)
    html = re.sub(r"<link\b[^>]*>", "", html)
    tab.set_content(html)
    tab.add_style_tag(content=(STATIC / "styles.css").read_text(encoding="utf-8"))
    tab.add_script_tag(content=ui_source())
    tab.evaluate("""() => {
      window.apiRequests = [];
      filterTest.state.backendReady = true;
      filterTest.state.initialized = true;
      filterTest.bindEvents();
      window.fetch = async (path, options = {}) => {
        window.apiRequests.push({path, method: options.method || 'GET', body: options.body});
        const id = decodeURIComponent(path.split('/').pop());
        return new Response(JSON.stringify(filterTest.state.jobs.get(id) || {}), {
          headers: {'Content-Type': 'application/json'}
        });
      };
    }""")
    try:
        yield tab
        assert not unexpected_requests
        assert not errors
    finally:
        context.close()


def item(status, **changes):
    result = {
        "id": f"item-{status}", "title": f"Item {status}", "status": status,
        "source_url": "https://www.douyin.com/video/123456", "retryable": False,
    }
    result.update(changes)
    return result


def job(identity, status="completed", **changes):
    result = {
        "id": identity, "author": identity, "platform": "douyin", "status": status,
        "source_kind": "profile", "source_url": "https://www.douyin.com/user/fixture",
        "created_at": "2026-01-01T00:00:00Z", "revision": 1,
        "discovery_complete": True, "items": [item("completed")],
    }
    result.update(changes)
    return result


def render(page, jobs, selected):
    page.evaluate("""({jobs, selected}) => {
      jobs.forEach(filterTest.upsertJob);
      filterTest.state.selectedJobId = selected;
      filterTest.renderSelectedJob();
    }""", {"jobs": jobs, "selected": selected})


def history_names(page):
    return page.locator("#history-list .history-copy strong").all_text_contents()


def item_names(page):
    return page.locator("#items-list .item-title").all_text_contents()


def send_event(page, payload):
    page.evaluate("job => filterTest.handleEvent({data: JSON.stringify(job)})", payload)


def history_filter(page, value):
    page.locator(f'#history-filter-tabs [data-history-filter="{value}"]').click()


def item_filter(page, value):
    page.locator(f'#filter-tabs [data-filter="{value}"]').click()


def test_history_filter_is_in_recent_task_panel_and_does_not_change_selection_or_request_work(page):
    jobs = [job(f"Job {status}", status) for status in JOB_STATUSES]
    render(page, jobs, "Job completed")
    expect(page.locator('.history-panel #history-filter-tabs [data-history-filter="unfinished"]')).to_have_count(1)
    assert history_names(page) == [entry["author"] for entry in jobs]
    before = page.evaluate("JSON.stringify([...filterTest.state.jobs.values()])")
    history_filter(page, "unfinished")
    assert history_names(page) == [entry["author"] for entry in jobs if entry["status"] != "completed"]
    assert page.evaluate("filterTest.state.selectedJobId") == "Job completed"
    expect(page.locator("#job-heading")).to_have_text("Job completed")
    expect(page.locator('#history-filter-tabs [data-history-filter="unfinished"]')).to_have_attribute("aria-pressed", "true")
    expect(page.locator('#history-filter-tabs [data-history-filter="all"]')).to_have_attribute("aria-pressed", "false")
    expect(page.locator("#history-summary")).to_contain_text(re.compile("当前|选中"))
    assert page.evaluate("apiRequests") == []
    history_filter(page, "all")
    assert history_names(page) == [entry["author"] for entry in jobs]
    assert page.evaluate("JSON.stringify([...filterTest.state.jobs.values()])") == before
    assert page.evaluate("apiRequests") == []


def test_completed_history_with_hidden_remaining_work_stays_visible(page):
    jobs = [
        job("Done"), job("Discovery incomplete", discovery_complete=False),
        job("Failed counter", failed_items=1), job("Count gap", total_items=3, completed_items=1),
        job("Unprocessed item", items=[item("queued")]),
        job("Skipped item", items=[item("skipped")]),
        job("Partial legacy", "partial", items=[]),
    ]
    render(page, jobs, "Done")
    history_filter(page, "unfinished")
    assert history_names(page) == [entry["author"] for entry in jobs[1:]]
    assert page.evaluate("apiRequests") == []


def test_item_filter_is_independent_of_history_and_existing_success_failure_filters(page):
    items = [item(status) for status in ITEM_STATUSES]
    render(page, [job("Mixed", "partial", items=items), job("Other done")], "Mixed")
    history_filter(page, "unfinished")
    item_filter(page, "unfinished")
    assert item_names(page) == [entry["title"] for entry in items if entry["status"] != "completed"]
    assert history_names(page) == ["Mixed"]
    assert page.evaluate("filterTest.state.selectedJobId") == "Mixed"
    expect(page.locator("#items-list .item-retry-button:visible")).to_have_count(0)
    item_filter(page, "success")
    assert item_names(page) == ["Item completed", "Item skipped", "Item partial"]
    item_filter(page, "failed")
    assert item_names(page) == ["Item needs_auth", "Item failed", "Item interrupted"]
    item_filter(page, "all")
    assert item_names(page) == [entry["title"] for entry in items]
    assert history_names(page) == ["Mixed"]
    history_filter(page, "all")
    assert history_names(page) == ["Mixed", "Other done"]
    assert page.evaluate("apiRequests") == []


def test_empty_history_and_empty_unfinished_result_are_distinguished(page):
    render(page, [], None)
    expect(page.locator("#history-list .history-empty")).to_contain_text("还没有下载任务")
    history_filter(page, "unfinished")
    expect(page.locator("#history-list .history-empty")).to_contain_text("还没有下载任务")
    render(page, [job("All done")], "All done")
    expect(page.locator("#history-list .history-empty")).to_contain_text("未完成")
    expect(page.locator("#job-heading")).to_have_text("All done")
    item_filter(page, "unfinished")
    expect(page.locator("#items-list .items-empty")).to_contain_text("未完成")
    assert page.evaluate("filterTest.state.selectedJobId") == "All done"
    assert page.evaluate("apiRequests") == []


def test_empty_discovery_does_not_claim_every_work_has_finished(page):
    render(page, [job("Discovering", "discovering", items=[], discovery_complete=False)], "Discovering")
    history_filter(page, "unfinished")
    item_filter(page, "unfinished")
    assert history_names(page) == ["Discovering"]
    expect(page.locator("#items-list .items-empty")).to_contain_text("尚未读取完整")
    assert page.evaluate("apiRequests") == []


def test_sse_updates_both_filters_immediately_without_changing_selected_job(page):
    render(page, [job("Selected", "downloading", items=[item("downloading")]), job("Other")], "Selected")
    history_filter(page, "unfinished")
    item_filter(page, "unfinished")
    assert history_names(page) == ["Selected"]
    assert item_names(page) == ["Item downloading"]
    send_event(page, job("Selected", revision=2))
    assert history_names(page) == []
    assert item_names(page) == []
    expect(page.locator("#job-heading")).to_have_text("Selected")
    send_event(page, job("Other", "failed", items=[item("failed")], revision=2))
    assert history_names(page) == ["Other"]
    assert page.evaluate("filterTest.state.selectedJobId") == "Selected"
    send_event(page, job("Selected", "partial", items=[item("failed")], revision=3))
    assert history_names(page) == ["Selected", "Other"]
    assert item_names(page) == ["Item failed"]
    assert page.evaluate("filterTest.state.historyFilter") == "unfinished"
    assert page.evaluate("filterTest.state.filter") == "unfinished"
    assert page.evaluate("apiRequests") == []


def test_same_completed_status_reclassifies_immediately_when_sse_details_change(page):
    render(page, [job("Selected")], "Selected")
    history_filter(page, "unfinished")
    assert history_names(page) == []
    send_event(page, job("Selected", revision=2, discovery_complete=False))
    assert history_names(page) == ["Selected"]
    send_event(page, job("Selected", revision=3, total_items=2, completed_items=1))
    assert history_names(page) == ["Selected"]
    send_event(page, job("Selected", revision=4, total_items=2, completed_items=2))
    assert history_names(page) == []
    assert page.evaluate("filterTest.state.selectedJobId") == "Selected"
    assert page.evaluate("apiRequests") == []


def test_history_filter_keeps_recent_first_order_and_explicit_row_selection(page):
    jobs = [
        job("Older", "failed", created_at="2026-01-01T00:00:00Z"),
        job("Done", created_at="2026-01-04T00:00:00Z"),
        job("Newer", "cancelled", created_at="2026-01-03T00:00:00Z"),
    ]
    render(page, jobs, "Done")
    history_filter(page, "unfinished")
    assert history_names(page) == ["Newer", "Older"]
    assert page.evaluate("apiRequests") == []
    page.locator("#history-list .history-item").filter(has_text="Older").click()
    expect(page.locator("#job-heading")).to_have_text("Older")
    assert page.evaluate("filterTest.state.selectedJobId") == "Older"
    assert page.evaluate("apiRequests") == [{"path": "/api/jobs/Older", "method": "GET", "body": None}]
    assert history_names(page) == ["Newer", "Older"]
    assert page.evaluate("filterTest.state.historyFilter") == "unfinished"


def test_filter_buttons_are_keyboard_usable_and_fit_narrow_layout(page):
    page.set_viewport_size({"width": 390, "height": 844})
    render(page, [job("Done"), job("Pending", "queued")], "Done")
    history_button = page.locator('#history-filter-tabs [data-history-filter="unfinished"]')
    history_button.focus()
    history_button.press("Space")
    expect(history_button).to_have_attribute("aria-pressed", "true")
    assert history_names(page) == ["Pending"]
    item_button = page.locator('#filter-tabs [data-filter="unfinished"]')
    item_button.focus()
    item_button.press("Enter")
    expect(item_button).to_have_attribute("aria-pressed", "true")
    for selector in ("#history-filter-tabs", "#filter-tabs"):
        assert page.locator(selector).evaluate("""element => {
          const box = element.getBoundingClientRect();
          return box.left >= 0 && box.right <= window.innerWidth;
        }""")
    assert page.evaluate("apiRequests") == []

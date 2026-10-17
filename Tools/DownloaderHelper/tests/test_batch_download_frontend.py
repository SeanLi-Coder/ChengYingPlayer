"""Exercise batch reporting and explicit safe-link copying without real accounts."""

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
EXPORT = """  window.batchTest = {
    itemSourceLink, batchStatusMessage, state, upsertJob, renderSelectedJob,
    handleEvent, copyItemLink, bindEvents
  };
})();
"""


def ui_source():
    source = (STATIC / "app.js").read_text(encoding="utf-8")
    assert source.count(MARKER) == 1
    return source.replace(MARKER, EXPORT)


def test_canonical_links_strip_tokens_and_never_copy_profiles_or_media():
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is unavailable")
    cases = [
        ("douyin", "https://www.douyin.com/video/123456?token=SECRET#private", "https://www.douyin.com/video/123456"),
        ("douyin", "https://www.douyin.com/note/123456/?from=private", "https://www.douyin.com/note/123456"),
        ("douyin", "https://www.iesdouyin.com/share/video/123456/", "https://www.douyin.com/video/123456"),
        ("kuaishou", "https://www.kuaishou.com/short-video/3xTest123?shareToken=SECRET", "https://www.kuaishou.com/short-video/3xTest123"),
        ("kuaishou", "https://m.gifshow.com/fw/photo/3xTest123/", "https://www.kuaishou.com/short-video/3xTest123"),
        ("xiaohongshu", "https://www.xiaohongshu.com/discovery/item/0123456789abcdef01234567?xsec_token=SECRET", "https://www.xiaohongshu.com/explore/0123456789abcdef01234567"),
        ("instagram", "https://www.instagram.com/p/Abc_DEF-123/media/?igsh=SECRET", "https://www.instagram.com/p/Abc_DEF-123/"),
        ("instagram", "https://www.instagram.com/reel/Abc_DEF-123/", "https://www.instagram.com/p/Abc_DEF-123/"),
        ("youtube", "https://www.youtube.com/watch?v=Abcdef_1234&list=PRIVATE&index=9", "https://www.youtube.com/watch?v=Abcdef_1234"),
        ("youtube", "https://youtu.be/Abcdef_1234?si=SECRET", "https://www.youtube.com/watch?v=Abcdef_1234"),
        ("youtube", "https://www.youtube.com/shorts/Abcdef_1234", "https://www.youtube.com/watch?v=Abcdef_1234"),
        ("bilibili", "https://www.bilibili.com/video/BV1234567890/?p=3&token=SECRET", "https://www.bilibili.com/video/BV1234567890?p=3"),
        ("bilibili", "https://www.bilibili.com/video/av1234", "https://www.bilibili.com/video/av1234"),
    ]
    rejected = [
        ("douyin", "https://www.douyin.com/user/author?modal_id=123456"),
        ("douyin", "https://v.douyin.com/shared"),
        ("douyin", "https://www.douyin.com.evil.test/video/123456"),
        ("douyin", "https://name:password@www.douyin.com/video/123456"),
        ("douyin", "https://www.douyin.com:9999/video/123456"),
        ("douyin", "http://www.douyin.com/video/123456"),
        ("douyin", "https://www.douyin.com/video/123456/other"),
        ("douyin", "https://www.douyin.com/video/%31%32%33"),
        ("douyin", "https://www.douyin.com/video/123\n456"),
        ("douyin", "https://v.example.test/file.mp4?signature=SECRET"),
        ("douyin", "javascript:alert('SECRET')"),
        ("douyin", "data:text/html,SECRET"),
        ("douyin", "file:///private/path"),
        ("douyin", "https://www.douyin.com/video/" + "9" * 25),
        ("kuaishou", "https://www.kuaishou.com/profile/3xTest123"),
        ("xiaohongshu", "https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567"),
        ("instagram", "https://www.instagram.com/private_profile/"),
        ("instagram", "https://www.instagram.com/p/Abc/other/"),
        ("youtube", "https://www.youtube.com/watch?v=Abcdef_1234&v=OtherID1234"),
        ("youtube", "https://www.youtube.com/@author/videos"),
        ("bilibili", "https://www.bilibili.com/video/BV1234567890?p=1&p=2"),
        ("bilibili", "https://www.bilibili.com/video/BV1234567890?p=SECRET"),
        ("unknown", "https://www.douyin.com/video/123456"),
        ("douyin", None),
    ]
    cases += [(platform, url, "") for platform, url in rejected]
    payload = json.dumps(cases)
    script = (
        "globalThis.window = {}; globalThis.document = {querySelector: () => null};\n"
        + ui_source()
        + f"\nconst cases = {payload};\n"
        + "const results = cases.map(([platform, source_url]) => window.batchTest.itemSourceLink("
        + "{source_url, media_id: '999999', metadata: {media_url: 'https://private.invalid/SECRET'}}, {platform}));"
        + "process.stdout.write(JSON.stringify(results));"
    )
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == [case[2] for case in cases]
    assert "SECRET" not in result.stdout


@pytest.fixture(scope="module")
def browser():
    if not CHROME.is_file():
        if os.environ.get("CHENGYING_REQUIRE_CHROME_UI") == "1":
            pytest.fail("The required real Chrome UI runtime is not installed")
        pytest.skip("The optional real Chrome UI runtime is not installed")
    with sync_playwright() as playwright:
        instance = playwright.chromium.launch(channel="chrome", headless=True,
                                              args=["--no-proxy-server"], timeout=15000)
        try:
            yield instance
        finally:
            instance.close()


@pytest.fixture
def page(browser):
    context = browser.new_context(service_workers="block", viewport={"width": 1000, "height": 1200})
    requests = []
    errors = []

    def deny_request(route):
        requests.append("unexpected request")
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
      window.copies = [];
      window.apiRequests = [];
      Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
        writeText: async value => {window.copies.push(value);}
      }});
      window.batchTest.state.backendReady = true;
      window.batchTest.state.initialized = true;
      window.batchTest.bindEvents();
      window.fetch = async (path, options = {}) => {
        window.apiRequests.push({path, method: options.method || 'GET', body: options.body});
        return new Response(JSON.stringify(window.batchTest.state.jobs.get('batch')), {
          headers: {'Content-Type': 'application/json'}
        });
      };
    }""")
    try:
        yield tab
        assert not requests
        assert not errors
    finally:
        context.close()


def sample_job(status="downloading", **changes):
    job = {
        "id": "batch", "platform": "douyin", "source_kind": "profile",
        "source_url": "https://www.douyin.com/user/author", "status": status,
        "author": "Fixture Author", "revision": 1, "discovery_complete": True, "auto_retry_enabled": True,
        "items": [
            {"id": "done", "title": "Completed item", "status": "completed", "source_url": "https://www.douyin.com/video/123001?token=SECRET"},
            {"id": "bad", "title": "Failed item", "status": "failed", "source_url": "https://www.douyin.com/video/123002", "issue_code": "network_error", "error": "Network request failed", "retryable": True},
            {"id": "wait", "title": "Queued item", "status": "queued", "source_url": "https://www.douyin.com/video/123003"},
        ],
    }
    job.update(changes)
    return job


def render(page, job):
    page.evaluate("""job => {
      batchTest.upsertJob(job);
      batchTest.state.selectedJobId = job.id;
      batchTest.renderSelectedJob();
    }""", job)


def test_each_status_can_copy_its_own_work_link_without_automatic_clipboard_access(page):
    render(page, sample_job())
    assert page.evaluate("copies") == []
    assert page.locator(".item-copy-button").count() == 3
    for index in range(3):
        page.locator(".item-copy-button").nth(index).click()
    assert page.evaluate("copies") == [f"https://www.douyin.com/video/12300{i}" for i in range(1, 4)]
    expect(page.locator("#batch-status")).to_contain_text("其余作品继续下载")
    expect(page.locator(".download-item.failed .item-error")).to_contain_text("网络")
    expect(page.locator("#retry-all-button")).to_be_hidden()
    assert page.evaluate("apiRequests") == []


@pytest.mark.parametrize("clipboard_mode", ["rejected", "missing"])
def test_clipboard_failure_selects_manual_text_without_real_clipboard(page, clipboard_mode):
    render(page, sample_job())
    page.evaluate("""mode => {
      Object.defineProperty(navigator, 'clipboard', {configurable: true,
        value: mode === 'missing' ? undefined : {writeText: async () => {throw new Error('denied');}}
      });
    }""", clipboard_mode)
    page.locator(".item-copy-button").nth(1).click()
    dialog = page.locator(".link-copy-dialog")
    expect(dialog).to_be_visible()
    field = dialog.locator("textarea")
    expect(field).to_have_value("https://www.douyin.com/video/123002")
    assert field.evaluate("e => e.selectionStart === 0 && e.selectionEnd === e.value.length && document.activeElement === e")
    expect(dialog).to_contain_text("⌘C")
    # SSE updates may replace the row while the manual-copy dialog is still open.
    page.evaluate("job => batchTest.handleEvent({data: JSON.stringify(job)})", sample_job(revision=2))
    expect(field).to_have_value("https://www.douyin.com/video/123002")
    field.press("Tab")
    expect(dialog.locator("button")).to_be_focused()
    dialog.locator("button").press("Escape")
    expect(dialog).to_have_count(0)
    assert page.evaluate("copies") == []


def test_unsafe_source_is_disabled_even_with_media_metadata(page):
    job = sample_job()
    job["items"][1]["source_url"] = "https://www.douyin.com/user/author"
    job["items"][1]["metadata"] = {"url": "https://media.invalid/file?SECRET"}
    render(page, job)
    expect(page.locator(".item-copy-button").nth(1)).to_be_disabled()
    assert page.evaluate("copies") == []


def test_manual_copy_works_without_native_dialog_api(page):
    render(page, sample_job())
    page.evaluate("""() => {
      Object.defineProperty(navigator, 'clipboard', {configurable: true, value: undefined});
      Object.defineProperty(HTMLDialogElement.prototype, 'showModal', {configurable: true, value: undefined});
    }""")
    page.locator(".item-copy-button").first.click()
    dialog = page.locator(".link-copy-dialog")
    expect(dialog).to_be_visible()
    expect(dialog.locator("textarea")).to_be_focused()
    dialog.locator("textarea").press("Shift+Tab")
    expect(dialog.locator("button")).to_be_focused()
    dialog.locator("button").click()
    expect(dialog).to_have_count(0)
    expect(page.locator(".item-copy-button").first).to_be_focused()


def test_failed_tail_round_has_continue_and_correct_existing_retry_api(page):
    job = sample_job(status="partial", auto_retry_round=1, auto_retry_total=1)
    job["items"][2]["status"] = "completed"
    render(page, job)
    expect(page.locator("#batch-status")).to_contain_text("自动补试已结束")
    expect(page.locator("#batch-status")).to_contain_text("仍有 1 个作品")
    expect(page.locator("#retry-all-button")).to_have_text(re.compile("继续下载"))
    page.locator("#retry-all-button").click()
    page.wait_for_function("apiRequests.some(r => r.method === 'POST')")
    assert page.evaluate("apiRequests.filter(r => r.method === 'POST')") == [
        {"path": "/api/jobs/batch/retry", "method": "POST", "body": "{}"}
    ]
    page.locator("[data-filter='failed']").click()
    expect(page.locator(".download-item")).to_have_count(1)
    page.locator(".item-retry-button").click()
    page.wait_for_function("apiRequests.filter(r => r.method === 'POST').length === 2")
    assert json.loads(page.evaluate("apiRequests.filter(r => r.method === 'POST')[1].body")) == {"item_id": "bad"}


def test_tail_round_progress_and_interruption_do_not_claim_full_completion(page):
    render(page, sample_job(auto_retry_round=1, auto_retry_total=1))
    expect(page.locator("#batch-status")).to_contain_text("正在补试 1 个")
    expect(page.locator("#retry-all-button")).to_be_hidden()
    render(page, sample_job(status="interrupted", auto_retry_round=1, auto_retry_total=1, revision=2))
    expect(page.locator("#batch-status")).to_contain_text("自动补试已暂停")
    expect(page.locator("#batch-status")).not_to_contain_text("已结束")
    expect(page.locator("#retry-all-button")).to_be_visible()


def test_standalone_or_old_records_do_not_promise_native_retry_policy(page):
    render(page, sample_job(auto_retry_enabled=False))
    expect(page.locator("#batch-status")).to_be_hidden()
    job = sample_job(revision=2)
    del job["auto_retry_enabled"]
    page.evaluate("batchTest.state.jobs.clear()")
    render(page, job)
    expect(page.locator("#batch-status")).to_be_hidden()
    render(page, sample_job(status="partial", revision=3, auto_retry_enabled=False,
                            auto_retry_round=1, auto_retry_total=1))
    expect(page.locator("#batch-status")).to_contain_text("自动补试已结束")


def test_version_gate_blocks_copy_and_rejection_fallback_after_race(page):
    render(page, sample_job())
    page.evaluate("""() => {
      navigator.clipboard.writeText = () => new Promise((resolve, reject) => {window.rejectCopy = reject;});
    }""")
    page.locator(".item-copy-button").first.click()
    page.evaluate("""() => {
      batchTest.state.versionBlocked = true;
      window.rejectCopy(new Error('denied'));
      batchTest.renderSelectedJob();
    }""")
    expect(page.locator(".item-copy-button").first).to_be_disabled()
    page.wait_for_timeout(20)
    expect(page.locator(".link-copy-dialog")).to_have_count(0)
    assert page.evaluate("copies") == []
    page.evaluate("() => batchTest.copyItemLink(batchTest.state.jobs.get('batch').items[0], {platform: 'douyin'})")
    expect(page.locator(".link-copy-dialog")).to_have_count(0)


def test_narrow_layout_keeps_copy_and_retry_controls_in_view(page):
    page.set_viewport_size({"width": 390, "height": 900})
    render(page, sample_job(status="partial", auto_retry_round=1, auto_retry_total=1))
    for button in page.locator(".item-copy-button, .item-retry-button:visible").all():
        bounds = button.bounding_box()
        assert bounds and bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390

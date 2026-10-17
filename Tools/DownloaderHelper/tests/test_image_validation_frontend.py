"""Verify image-validation messages against production JS using synthetic jobs."""

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
EXPORT = """  window.imageTest = {
    localizeRuntimeMessage, state, upsertJob, renderSelectedJob, handleEvent
  };
})();
"""
UNVERIFIED = "Highest-available image dimensions could not be verified"
BELOW = "Media server returned an image below its declared 2160x3840 resolution"
LABELS = {
    "douyin": "抖音", "xiaohongshu": "小红书", "kuaishou": "快手",
    "instagram": "Instagram", "bilibili": "B站", "youtube": "YouTube",
}


def ui_source():
    source = (STATIC / "app.js").read_text(encoding="utf-8")
    assert source.count(MARKER) == 1
    return source.replace(MARKER, EXPORT)


def localize(message, job):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is unavailable")
    script = (
        "globalThis.window = {}; globalThis.document = {querySelector: () => null};\n"
        + ui_source()
        + "\nprocess.stdout.write(JSON.stringify(window.imageTest.localizeRuntimeMessage("
        + json.dumps(message) + "," + json.dumps(job) + ")));"
    )
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=30, check=False)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize(("platform", "label"), LABELS.items())
@pytest.mark.parametrize("message", [UNVERIFIED, BELOW, UNVERIFIED + "; " + BELOW])
def test_supported_platforms_have_distinct_evidence_based_image_messages(platform, label, message):
    text = localize(message, {"platform": platform})
    assert text.startswith(label + "图片的")
    assert "脱敏诊断" in text
    assert "低清占位图" not in text
    assert "会尝试下一条" not in text
    if UNVERIFIED in message and BELOW in message:
        assert "尺寸低于声明值和尺寸无法验证" in text
        assert "不能只归因为低清" in text
    elif message == UNVERIFIED:
        assert "尺寸未能读取或验证" in text
        assert "不能据此认定图片是低清" in text
        assert "实测尺寸低于" not in text
    else:
        assert "实测尺寸低于作品声明值" in text
        assert "尺寸未能读取或验证" not in text


@pytest.mark.parametrize("platform", [
    None, "", "unknown", "__proto__", "constructor", "toString", 123,
    [], {"label": "douyin"}, "fake-douyin-site", '<img src=x onerror="window.injected=true">',
])
def test_unknown_or_malicious_platform_uses_generic_label_not_site_or_url_inference(platform):
    text = localize(UNVERIFIED, {
        "platform": platform, "site": "xiaohongshu", "source_url": "https://www.douyin.com/video/123",
    })
    assert text.startswith("当前图片的")
    assert not any(label in text for label in LABELS.values())
    assert "img src" not in text
    assert "window.injected" not in text
    assert "[object Object]" not in text


def test_missing_job_is_generic_and_known_platform_is_case_normalized():
    assert localize(UNVERIFIED, None).startswith("当前图片的")
    assert localize(UNVERIFIED, {"platform": " DOUYIN "}).startswith("抖音图片的")


def test_wrapped_image_failure_does_not_echo_raw_media_urls_or_tokens():
    raw = f"Image 2 failed: {UNVERIFIED}; https://example.invalid/media?token=synthetic-private-token"
    text = localize(raw, {"platform": "douyin"})
    assert text.startswith("抖音图片的")
    assert "example.invalid" not in text
    assert "synthetic-private-token" not in text
    assert "Image 2 failed" not in text


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
    try:
        yield tab
        assert not unexpected_requests
        assert not errors
    finally:
        context.close()


def sample_job(platform, message, revision=1):
    return {
        "id": "image-validation", "platform": platform, "author": "Synthetic Author",
        "status": "failed", "source_kind": "item", "created_at": "2026-01-01T00:00:00Z",
        "revision": revision, "error": "1 item(s) failed", "discovery_complete": True,
        "items": [{
            "id": "image-2", "title": "Synthetic image", "status": "failed", "media_type": "image",
            "error": message, "retryable": True, "source_url": "https://example.invalid/work",
        }],
    }


def render(page, job):
    page.evaluate("""job => {
      imageTest.upsertJob(job);
      imageTest.state.selectedJobId = job.id;
      imageTest.renderSelectedJob();
    }""", job)


@pytest.mark.parametrize(("platform", "label"), LABELS.items())
def test_actual_item_and_job_warning_render_correct_platform_and_update_without_stale_reason(page, platform, label):
    render(page, sample_job(platform, UNVERIFIED))
    for selector in (".item-error", "#warning-message"):
        expect(page.locator(selector)).to_contain_text(label + "图片的尺寸未能读取或验证")
        expect(page.locator(selector)).not_to_contain_text("低清占位图")
        if platform != "xiaohongshu":
            expect(page.locator(selector)).not_to_contain_text("小红书")
    page.evaluate("job => imageTest.handleEvent({data: JSON.stringify(job)})", sample_job(platform, BELOW, 2))
    for selector in (".item-error", "#warning-message"):
        expect(page.locator(selector)).to_contain_text(label + "图片的实测尺寸低于作品声明值")
        expect(page.locator(selector)).not_to_contain_text("尺寸未能读取或验证")


def test_dom_uses_generic_safe_text_for_unknown_platform_and_wrapped_failure(page):
    raw = f"Image 1 failed: {UNVERIFIED}; https://example.invalid/?token=synthetic-private-token"
    render(page, sample_job('<img src=x onerror="window.injected=true">', raw))
    for selector in (".item-error", "#warning-message"):
        expect(page.locator(selector)).to_contain_text("当前图片的尺寸未能读取或验证")
        expect(page.locator(selector)).not_to_contain_text("synthetic-private-token")
        expect(page.locator(selector)).not_to_contain_text("example.invalid")
        assert page.locator(selector + " img").count() == 0
    assert page.evaluate("window.injected === undefined")

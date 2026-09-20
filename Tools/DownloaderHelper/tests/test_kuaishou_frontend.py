"""Exercise the actual downloader UI without browser sessions or public requests."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

HELPER_ROOT = Path(__file__).resolve().parents[1]
STATIC_ROOT = HELPER_ROOT / "vendor" / "rednote" / "app" / "static"


def run_ui(expression: str) -> object:
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node.js is unavailable")
    source = (STATIC_ROOT / "app.js").read_text(encoding="utf-8")
    marker = "  initialize();\n})();\n"
    assert source.count(marker) == 1
    source = source.replace(
        marker,
        "  window.testAPI = {getPlatform, platformMeta, isProfileJob, "
        "verificationTarget, localizeDiscoveryActivity, localizeRuntimeMessage};\n})();\n",
    )
    result = subprocess.run(
        [node, "-e", "globalThis.window = {};\n"
         "globalThis.document = {querySelector: () => null};\n" + source
         + f"\nprocess.stdout.write(JSON.stringify({expression}));\n"],
        capture_output=True, text=True, encoding="utf-8", timeout=30, check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize("url", [
    "https://www.kuaishou.com/short-video/3x12345678",
    "https://www.kuaishou.com/profile/3x98765432",
    "https://v.kuaishou.com/abcdef",
    "https://m.gifshow.com/fw/photo/3x12345678",
    "https://m.gifshow.com/fw/user/3x98765432",
])
def test_kuaishou_jobs_have_a_recognizable_platform(url):
    assert run_ui(f"window.testAPI.platformMeta({json.dumps({'url': url})})") == {
        "key": "kuaishou", "glyph": "快", "label": "快手",
    }


@pytest.mark.parametrize(("job", "expected"), [
    ({"platform": "kuaishou", "source_kind": "profile"}, "原主页"),
    ({"platform": "kuaishou", "source_kind": "item"}, "原视频"),
    ({"url": "https://www.kuaishou.com/profile/3x98765432"}, "原主页"),
    ({"url": "https://m.gifshow.com/fw/user/3x98765432"}, "原主页"),
    ({"url": "https://v.kuaishou.com/abcdef", "source_kind": "profile"}, "原主页"),
    ({"platform": "kuaishou", "source_kind": "short_link", "resolved_source_kind": "profile"}, "原主页"),
    ({"url": "https://www.kuaishou.com/short-video/3x12345678"}, "原视频"),
])
def test_verification_opens_the_correct_kind_of_original_page(job, expected):
    assert run_ui(f"window.testAPI.verificationTarget({json.dumps(job)})") == expected


@pytest.mark.parametrize("platform", ["xiaohongshu", "bilibili", "youtube", "douyin"])
def test_existing_platform_identity_is_preserved(platform):
    assert run_ui(f"window.testAPI.getPlatform({json.dumps({'platform': platform})})") == platform


def test_entry_form_advertises_supported_kuaishou_inputs_and_login_limit():
    source = (STATIC_ROOT / "index.html").read_text(encoding="utf-8")
    assert 'platform-dot orange' in source
    assert "快手支持单个视频、分享短链接和作者主页批量下载" in source
    assert "如网站要求登录或验证" in source
    assert "有权保存" in source


@pytest.mark.parametrize(("message", "expected"), [
    ("Opening Kuaishou in Chrome to read verified video metadata", "正在通过 Chrome"),
    ("Kuaishou: verified 37 videos across 3 pages", "已验证 37 个视频（3 页）"),
    ("Refreshing Kuaishou video links before download", "刷新下载地址"),
    ("Kuaishou profile discovery is incomplete. Only verified videos were queued; retry.", "不能把当前数量视为全部作品"),
    ("Kuaishou requires security verification. Open Chrome to complete the challenge, then retry.", "不会绕过验证码"),
    ("Kuaishou requires login. Open Chrome to sign in, enable Chrome Cookie, then retry.", "开启 Chrome Cookie"),
    ("Kuaishou Chrome cookies could not be read. Quit Chrome and retry.", "不会静默切换账号"),
    ("Kuaishou profile video belongs to a different author; the response was blocked", "身份未通过校验"),
    ("Kuaishou share link target changed; retry with a new task", "指向的作品或作者已变化"),
    ("Kuaishou media redirect was blocked before requesting an untrusted target", "不可信地址"),
    ("Kuaishou was blocked by the local DNS or web filter. Check the configured proxy or network policy; Chrome verification is not required.", "不是快手验证码"),
    ("Kuaishou browser TLS certificate verification failed. Check the configured proxy certificate or network policy; certificate verification was not disabled.", "不会关闭证书验证"),
])
def test_kuaishou_activity_and_errors_are_localized_without_losing_limits(message, expected):
    result = run_ui(
        f"window.testAPI.localizeRuntimeMessage({json.dumps(message)}, {{platform:'kuaishou'}})"
    )
    assert expected in result
    assert "Kuaishou" not in result


def test_live_discovery_progress_reports_verified_items_not_an_invented_total():
    result = run_ui(
        "window.testAPI.localizeDiscoveryActivity('Kuaishou: verified 37 videos across 3 pages',"
        " {platform:'kuaishou', source_kind:'profile'})"
    )
    assert result == "正在读取快手主页，已验证 37 个视频（3 页）"

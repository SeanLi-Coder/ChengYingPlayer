"""Exercise local-folder guidance without accounts, browser data or network."""

import json

import pytest
from test_kuaishou_frontend import run_ui


@pytest.mark.parametrize("message", [
    "The author download folder could not be prepared",
    "The author download folder conflicts with an existing file",
    "The author download folder is not a safe direct child of the selected directory",
    "The author download folder changed during preparation",
])
@pytest.mark.parametrize("code", ["local_configuration", "unknown"])
def test_folder_error_never_sends_user_to_chrome_or_brew(message, code):
    job = {"platform": "douyin", "status": "failed", "issue_code": code,
           "error": message, "items": []}
    rendered = run_ui("window.testAPI.warningPresentation(" + json.dumps(job) + ")")
    assert rendered["title"] == "作者保存目录准备失败"
    assert "本地保存目录" in rendered["message"]
    assert "旧任务仍使用原位置" in rendered["message"]
    assert "不要删除已有文件" in rendered["message"]
    assert "brew install" not in rendered["message"]
    assert "完全退出 Chrome" not in rendered["message"]

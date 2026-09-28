"""Run the real cookie settings handlers with isolated DOM and HTTP fixtures."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

STATIC = Path(__file__).resolve().parents[1] / "vendor/rednote/app/static"


def run_settings(script: str) -> dict:
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is unavailable")
    source = (STATIC / "app.js").read_text()
    marker = "  initialize();\n})();\n"
    assert source.count(marker) == 1
    source = source.replace(marker, """
  const calls = [], toasts = [];
  let response = {}, fail = false, delay = null;
  api = async (path, options = {}) => {
    calls.push({path, ...options});
    if (fail) throw new Error('Synthetic save failure');
    if (delay) await delay;
    return response;
  };
  showToast = (message) => toasts.push(message);
  window.test = {elements, state, calls, toasts, loadConfig, saveConfig, createJob,
    setResponse: value => {response = value;}, setFailure: () => {fail = true;},
    setDelay: value => {delay = value;}};
})();
""")
    harness = """
globalThis.window = {setTimeout() {}};
const nodes = new Map();
globalThis.document = {querySelector(selector) {
  if (!nodes.has(selector)) nodes.set(selector, {
    value: '', checked: true, textContent: '', disabled: false, focus() {this.focused = true;}
  });
  return nodes.get(selector);
}};
"""
    result = subprocess.run(
        [node, "-e", harness + source + "\n(async () => {\n" + script
         + "\n})().catch(e => {console.error(e); process.exitCode = 1;});"],
        capture_output=True, text=True, timeout=20, check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


@pytest.mark.parametrize("profile", [None, "Default", "Profile 3"])
def test_saved_profile_is_visible_without_saving_or_creating_jobs(profile):
    result = run_settings(f"""
const t = window.test;
t.setResponse({json.dumps({'chrome_profile': profile, 'use_chrome_cookies': True, 'download_dir': '/fixture'})});
await t.loadConfig();
console.log(JSON.stringify({{value: t.elements.chromeProfile.value, calls: t.calls}}));
""")
    assert result["value"] == (profile or "")
    assert result["calls"] == [{"path": "/api/config"}]


@pytest.mark.parametrize("profile", ["Default", "Profile 3", ""])
def test_profile_save_is_explicit_and_does_not_rebind_old_jobs(profile):
    result = run_settings(f"""
const t = window.test;
t.state.chromeProfile = 'Profile 2';
t.elements.chromeProfile.value = {json.dumps(profile)};
t.elements.downloadDir.value = '/fixture';
await t.saveConfig({{preventDefault() {{}}}});
console.log(JSON.stringify({{profile: t.state.chromeProfile, calls: t.calls, toasts: t.toasts}}));
""")
    assert result["profile"] == (profile or None)
    assert len(result["calls"]) == 1
    assert result["calls"][0]["path"] == "/api/config"
    assert json.loads(result["calls"][0]["body"])["chrome_profile"] == (profile or None)
    assert "旧任务保留原来的设置" in result["toasts"][0]


@pytest.mark.parametrize("profile", ["../Default", "/private/profile", "Profile 0", "Person 1"])
def test_new_invalid_profile_is_not_sent(profile):
    result = run_settings(f"""
const t = window.test;
t.elements.chromeProfile.value = {json.dumps(profile)};
t.elements.downloadDir.value = '/fixture';
await t.saveConfig({{preventDefault() {{}}}});
console.log(JSON.stringify({{calls: t.calls, focused: t.elements.chromeProfile.focused}}));
""")
    assert result == {"calls": [], "focused": True}


def test_unsaved_profile_blocks_job_creation_and_failed_save_preserves_state():
    result = run_settings("""
const t = window.test;
t.state.chromeProfile = 'Default';
t.elements.chromeProfile.value = 'Profile 2';
t.elements.downloadDir.value = '/fixture';
await t.createJob({preventDefault() {}});
const createCalls = t.calls.length;
const message = t.elements.formError.textContent;
t.setFailure();
await t.saveConfig({preventDefault() {}});
console.log(JSON.stringify({createCalls, message, profile: t.state.chromeProfile}));
""")
    assert result["createCalls"] == 0
    assert "请先保存" in result["message"]
    assert result["profile"] == "Default"


def test_cookie_decryption_diagnostic_does_not_assert_keychain_denial():
    source = (STATIC / "app.js").read_text()
    assert "此提示本身不能证明钥匙串拒绝授权" in source
    assert "不要删除钥匙串条目" in source
    html = (STATIC / "index.html").read_text()
    assert 'id="chrome-profile"' in html
    assert 'aria-describedby="chrome-profile-help"' in html
    assert "重试旧任务仍使用原设置" in html


def test_create_and_duplicate_save_cannot_race_profile_save():
    result = run_settings("""
const t = window.test;
t.state.chromeProfile = 'Default';
t.elements.chromeProfile.value = 'Profile 2';
t.elements.downloadDir.value = '/fixture';
let release;
t.setDelay(new Promise(resolve => {release = resolve;}));
const saving = t.saveConfig({preventDefault() {}});
t.elements.chromeProfile.value = 'Default';
await t.createJob({preventDefault() {}});
await t.saveConfig({preventDefault() {}});
const busy = t.state.settingsSaving;
release();
await saving;
console.log(JSON.stringify({calls: t.calls, busy, profile: t.state.chromeProfile,
  input: t.elements.chromeProfile.value, saving: t.state.settingsSaving}));
""")
    assert len(result["calls"]) == 1
    assert result["calls"][0]["path"] == "/api/config"
    assert result["busy"] is True and result["saving"] is False
    assert result["profile"] == result["input"] == "Profile 2"


def test_unedited_legacy_profile_with_whitespace_survives_other_settings_save():
    result = run_settings("""
const t = window.test;
t.state.chromeProfile = '/fixture/Legacy Profile ';
t.elements.chromeProfile.value = t.state.chromeProfile;
t.elements.downloadDir.value = '/fixture';
await t.saveConfig({preventDefault() {}});
console.log(JSON.stringify({calls: t.calls, profile: t.state.chromeProfile}));
""")
    assert result["profile"] == "/fixture/Legacy Profile "
    assert json.loads(result["calls"][0]["body"])["chrome_profile"] == result["profile"]

"use strict";

(() => {
  const original = document.querySelector("#chrome-profile");
  const settingsForm = document.querySelector("#settings-form");
  const downloadForm = document.querySelector("#download-form");
  const originalCookies = document.querySelector("#chrome-cookies");
  const saveButton = document.querySelector("#save-settings-button");
  if (!original || !settingsForm || !downloadForm || !originalCookies || !saveButton ||
      document.querySelector("#desktop-chrome-profile")) return;

  const INVALID_SAVED = "__saved_invalid_profile__";
  const MAX_RESPONSE_BYTES = 64 * 1024;
  const scanMessages = Object.freeze({
    chrome_data_directory_missing: "没有找到 Chrome 用户资料。请先在 Chrome 中建立用户配置并访问目标网站，再刷新列表。",
    cookie_permission_denied: "目前无法读取 Chrome 配置目录。请检查 macOS 文件访问权限后刷新，不要删除浏览器资料。",
    cookie_storage_failed: "读取 Chrome 配置目录失败。请检查本机存储是否可用后刷新。",
    profile_scan_limit: "Chrome 配置过多，本次无法完整核实。请检查浏览器配置后刷新；程序不会猜测账号。",
    unavailable: "无法核实 Chrome 用户配置。请点击“刷新配置列表”重试，当前选择不会被替换。"
  });
  const statuses = new Set(["available", "missing", "invalid", "automatic", "cookie_database_missing", "unverified"]);
  let disposed = false;
  let generation = 0;
  let loading = false;
  let saving = false;
  let loaded = false;
  let draftChanged = false;
  let cookieDraftChanged = false;
  let savedProfile = null;
  let savedStatus = "automatic";
  let savedCookies = true;
  let scanStatus = "unavailable";
  let profiles = [];
  let controller = null;

  function node(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text) result.textContent = text;
    return result;
  }

  // Own the visible draft separately: the preserved frontend's asynchronous
  // initial load may still write its original controls after the user edits.
  const cookies = node("input");
  cookies.id = "desktop-chrome-cookies";
  cookies.type = "checkbox";
  cookies.setAttribute("role", "switch");
  cookies.setAttribute("aria-label", "自动读取 Chrome Cookie");
  cookies.checked = originalCookies.checked;
  originalCookies.type = "hidden";
  originalCookies.setAttribute("aria-hidden", "true");
  originalCookies.after(cookies);
  const cookieLabel = document.querySelector('label[for="chrome-cookies"]');
  if (cookieLabel) cookieLabel.htmlFor = cookies.id;
  const panel = node("div", "desktop-chrome-profiles");
  const select = node("select", "desktop-chrome-profile");
  select.id = "desktop-chrome-profile";
  select.setAttribute("aria-label", "本机 Chrome 用户配置");
  select.setAttribute("aria-describedby", "desktop-chrome-profile-status desktop-chrome-profile-note");
  const refresh = node("button", "desktop-chrome-profile-refresh", "刷新配置列表");
  refresh.id = "desktop-chrome-profile-refresh";
  refresh.type = "button";
  const status = node("p", "desktop-chrome-profile-status", "正在核实本机 Chrome 用户配置…");
  status.id = "desktop-chrome-profile-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  const note = node("p", "desktop-chrome-profile-note", "只列出本机实际存在的配置文件夹，不读取或显示账号邮箱。存在 Cookie 数据库不代表已登录或可以成功解密。修改后请保存下载设置并从原链接新建任务；旧任务仍使用原来的配置。");
  note.id = "desktop-chrome-profile-note";
  panel.append(select, refresh, status, note);
  original.hidden = true;
  original.setAttribute("aria-hidden", "true");
  original.setAttribute("tabindex", "-1");
  original.after(panel);
  const label = document.querySelector('label[for="chrome-profile"]');
  if (label) label.htmlFor = select.id;
  const oldHelp = document.querySelector("#chrome-profile-help");
  if (oldHelp) oldHelp.hidden = true;

  function blocked() {
    return disposed || document.body.classList.contains("version-blocked");
  }

  function validDirectory(value) {
    return typeof value === "string" && value.length <= 80 && /^(?:Default|Profile [1-9][0-9]*)$/.test(value);
  }

  function savedValue() {
    return savedStatus === "invalid" ? INVALID_SAVED : (savedProfile || "");
  }

  function dirty() {
    return select.value !== savedValue() || cookies.checked !== savedCookies;
  }

  function selectedIssue() {
    if (!cookies.checked) return "";
    if (select.value === INVALID_SAVED) return "已保存的 Profile 名称无效。请选择本机实际存在的配置并保存；程序不会自动换号。";
    if (select.value === "") return "";
    const selected = profiles.find((profile) => profile.directory === select.value);
    if (!selected) return "当前选择的 Profile 已不存在。请选择下方实际存在的配置并保存，再从原链接新建任务；旧任务不会自动换号。";
    if (!selected.has_cookie_database) return "这个 Profile 尚无 Cookie 数据库。请用它在 Chrome 中访问目标网站后刷新列表。";
    return "";
  }

  function update() {
    select.disabled = blocked() || loading || saving || !loaded || scanStatus !== "ok";
    refresh.disabled = blocked() || loading || saving;
    panel.setAttribute("aria-busy", String(loading || saving));
    let message;
    let error = false;
    if (loading) message = "正在核实本机 Chrome 用户配置…";
    else if (saving) message = "正在保存下载设置，完成后会重新核实配置…";
    else if (!loaded || scanStatus !== "ok") {
      message = scanMessages[scanStatus] || scanMessages.unavailable;
      error = true;
      if (loaded && !savedCookies && !cookies.checked) message += "已保存关闭 Cookie，仍可按无 Cookie 模式新建任务。";
      else if (loaded && savedProfile === null && savedStatus === "automatic" && !dirty()) {
        message += "仍保留已保存的自动模式，可以继续尝试下载；自动模式不保证使用当前账号。";
      }
    } else if (!cookies.checked) {
      message = dirty() ? "关闭 Cookie 的修改尚未保存，请先保存下载设置。" : "已保存关闭 Cookie；保留原 Profile 选择，不读取其 Cookie。";
    } else {
      message = selectedIssue();
      error = Boolean(message);
      if (!message && dirty()) message = "Profile 已选择但尚未保存，请先点击下方“保存设置”；旧任务不会改变。";
      else if (!message && select.value === "") message = "保留自动选择：抖音会使用最近更新的 Cookie 数据库，不保证是当前账号。想固定账号，请选择对应 Profile 并保存。";
      else if (!message) message = `已保存 ${select.value}。只核实目录和数据库存在，不代表网站登录或 Cookie 解密已经成功。`;
    }
    status.textContent = message;
    status.classList.toggle("is-error", error);
  }

  function renderOptions(value) {
    select.replaceChildren();
    const automatic = node("option", "", "自动选择（不固定账号）");
    automatic.value = "";
    select.append(automatic);
    for (const profile of profiles) {
      const option = node("option", "", profile.directory + (profile.has_cookie_database ? "" : "（尚无 Cookie 数据库）"));
      option.value = profile.directory;
      select.append(option);
    }
    if (value === INVALID_SAVED || (value && !profiles.some((profile) => profile.directory === value))) {
      const missing = node("option", "", value === INVALID_SAVED ? "已保存的配置名称无效（未更改）" :
        `${value}（${scanStatus === "ok" ? "已不存在" : "尚未核实"}，原设置保留）`);
      missing.value = value;
      missing.disabled = true;
      select.append(missing);
    }
    select.value = value;
  }

  function readState(data) {
    if (!data || typeof data !== "object" || data.schema_version !== 1 ||
        typeof data.use_chrome_cookies !== "boolean" || !statuses.has(data.selected_status) ||
        !(data.selected_profile === null || validDirectory(data.selected_profile)) ||
        !(data.status === "ok" || Object.hasOwn(scanMessages, data.status)) ||
        !Array.isArray(data.profiles) || data.profiles.length > 256) throw new Error("Invalid profile response");
    const seen = new Set();
    for (const profile of data.profiles) {
      if (!profile || !validDirectory(profile.directory) || typeof profile.has_cookie_database !== "boolean" ||
          seen.has(profile.directory)) throw new Error("Invalid profile response");
      seen.add(profile.directory);
    }
    if (data.selected_status !== "unverified" &&
        (["automatic", "invalid"].includes(data.selected_status)) !== (data.selected_profile === null)) {
      throw new Error("Invalid selected profile");
    }
    return data;
  }

  async function readResponse(response, signal) {
    if (response.status !== 200 || !/^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") || "")) {
      throw new Error("Invalid profile response");
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Missing profile response");
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let text = "";
    let bytes = 0;
    let complete = false;
    try {
      while (true) {
        if (signal.aborted) throw new Error("Profile request cancelled");
        const chunk = await reader.read();
        if (signal.aborted) throw new Error("Profile request cancelled");
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (bytes > MAX_RESPONSE_BYTES) throw new Error("Oversized profile response");
        text += decoder.decode(chunk.value, { stream: true });
      }
      text += decoder.decode();
      complete = true;
      return readState(JSON.parse(text));
    } finally {
      if (!complete) {
        try { await reader.cancel(); } catch { /* Do not disclose transport errors. */ }
      }
      reader.releaseLock();
    }
  }

  async function load() {
    if (blocked() || loading || saving) return;
    loading = true;
    const identifier = ++generation;
    const request = new AbortController();
    controller = request;
    const timeout = setTimeout(() => request.abort(), 10000);
    update();
    try {
      const response = await fetch("/api/native/chrome-profiles", {
        method: "GET", credentials: "same-origin", cache: "no-store",
        headers: { Accept: "application/json" }, signal: request.signal
      });
      const data = await readResponse(response, request.signal);
      if (blocked() || identifier !== generation) return;
      const value = draftChanged ? select.value : (data.selected_status === "invalid" ? INVALID_SAVED : (data.selected_profile || ""));
      profiles = data.profiles;
      savedProfile = data.selected_profile;
      savedStatus = data.selected_status;
      savedCookies = data.use_chrome_cookies;
      scanStatus = data.status;
      loaded = true;
      if (!cookieDraftChanged) cookies.checked = savedCookies;
      originalCookies.checked = cookies.checked;
      renderOptions(value);
      // Preserve legacy invalid values privately until the user chooses a new
      // profile. The original frontend owns saving and its own state snapshot.
      if (!draftChanged && value !== INVALID_SAVED) original.value = value;
    } catch {
      if (blocked() || identifier !== generation) return;
      loaded = false;
      scanStatus = "unavailable";
    } finally {
      clearTimeout(timeout);
      if (identifier === generation) {
        controller = null;
        loading = false;
        update();
      }
    }
  }

  function reject(event, message) {
    event.preventDefault();
    event.stopImmediatePropagation();
    status.textContent = message;
    status.classList.add("is-error");
    const formError = document.querySelector("#form-error");
    if (formError) formError.textContent = message;
    (select.disabled ? refresh : select).focus();
  }

  function guard(event, newJob) {
    if (blocked()) {
      reject(event, "下载组件当前不可用，请先完成版本检查或重新打开下载中心。");
      return false;
    }
    if (saving || saveButton.disabled) {
      reject(event, "下载设置正在保存，请等待保存和配置核实完成。");
      return false;
    }
    if (loading || !loaded) {
      reject(event, "尚未完成 Chrome 配置核实，请等待或点击“刷新配置列表”。");
      return false;
    }
    if (!cookies.checked && !newJob) return true;
    // Changing the output folder must not silently repair or discard an old
    // explicit profile. Only new tasks and deliberate identity changes require
    // availability; the server enforces this same distinction.
    if (!newJob && !dirty()) return true;
    if (newJob && dirty()) {
      reject(event, "Chrome Profile 或 Cookie 开关已修改，请先保存下载设置，再从原链接新建任务。");
      return false;
    }
    if (!cookies.checked && !savedCookies) return true;
    // A saved automatic choice retains upstream extraction semantics. A
    // metadata-only inventory failure is not evidence that extraction failed.
    if (select.value === "") return true;
    if (scanStatus !== "ok") {
      reject(event, scanMessages[scanStatus] || scanMessages.unavailable);
      return false;
    }
    const issue = selectedIssue();
    if (issue) {
      reject(event, issue);
      return false;
    }
    return true;
  }

  select.addEventListener("change", () => {
    if (blocked() || loading || saving || select.value === INVALID_SAVED) return;
    draftChanged = true;
    original.value = select.value;
    original.dispatchEvent(new Event("input", { bubbles: true }));
    original.dispatchEvent(new Event("change", { bubbles: true }));
    update();
  });
  cookies.addEventListener("change", () => {
    cookieDraftChanged = true;
    originalCookies.checked = cookies.checked;
    update();
  });
  refresh.addEventListener("click", load);
  function synchronizeInputs() {
    if (select.value !== INVALID_SAVED) original.value = select.value;
    originalCookies.checked = cookies.checked;
  }
  downloadForm.addEventListener("submit", (event) => {
    if (guard(event, true)) synchronizeInputs();
  }, true);
  settingsForm.addEventListener("submit", (event) => {
    if (!guard(event, false)) return;
    synchronizeInputs();
    saving = true;
    update();
  }, true);
  // The original listener runs first in the bubbling phase. If it rejected its
  // own validation synchronously, no save started and no completion is expected.
  settingsForm.addEventListener("submit", () => {
    if (saving && !saveButton.disabled) {
      saving = false;
      update();
    }
  });
  const saveObserver = new MutationObserver(() => {
    if (!saving || saveButton.disabled || blocked()) return;
    saving = false;
    loaded = false;
    load();
  });
  saveObserver.observe(saveButton, { attributes: true, attributeFilter: ["disabled"] });
  const versionObserver = new MutationObserver(() => {
    if (blocked()) controller?.abort();
    update();
  });
  versionObserver.observe(document.body, { attributes: true, attributeFilter: ["class"] });
  window.addEventListener("pagehide", () => {
    disposed = true;
    generation += 1;
    controller?.abort();
    saveObserver.disconnect();
    versionObserver.disconnect();
    update();
  }, { once: true });
  renderOptions("");
  update();
  load();
})();

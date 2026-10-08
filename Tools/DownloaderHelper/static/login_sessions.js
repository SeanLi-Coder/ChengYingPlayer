"use strict";

(() => {
  const settings = document.querySelector("#settings-form");
  const downloads = document.querySelector("#download-form");
  const originalCookies = document.querySelector("#chrome-cookies");
  const originalProfile = document.querySelector("#chrome-profile");
  const settingsSave = document.querySelector("#save-settings-button");
  if (!settings || !downloads || !originalCookies || !originalProfile ||
      document.querySelector("#desktop-login-panel")) return;

  const PLATFORMS = Object.freeze({
    douyin: "抖音", xiaohongshu: "小红书", kuaishou: "快手",
    instagram: "Instagram", bilibili: "B站", youtube: "YouTube"
  });
  const MODES = new Set(["dedicated", "chrome", "anonymous"]);
  const STATUSES = new Set(["idle", "opening", "login_open", "saving", "saved", "error"]);
  const ACTIVE = new Set(["opening", "login_open", "saving"]);
  const ERRORS = Object.freeze({
    login_platform_invalid: "登录平台无效，请重新打开下载中心。",
    login_session_invalid: "本地登录记录无法安全读取，请重新打开专用窗口并保存登录。",
    login_storage_unavailable: "无法访问专用登录的本机数据目录，请检查存储空间和文件权限；无需为日常 Chrome 添加权限。",
    login_closed: "登录服务已关闭，请重新打开下载中心。",
    login_session_missing: "还没有此平台的专用登录，请打开登录窗口并手动登录。",
    login_session_expired: "本地登录记录已过期，请重新登录并保存，然后新建下载任务。",
    login_proxy_unavailable: "当前代理不可用，请检查并保存代理设置后重试；不会自动改为直连。",
    login_busy: "还有登录操作正在处理，请先完成或关闭该专用窗口，再刷新状态。",
    login_not_open: "专用登录窗口尚未打开，请先点击“打开登录窗口”。",
    login_session_empty: "尚未获得可保存的登录信息，请在专用窗口完成登录后再试。",
    login_window_closed: "专用窗口已关闭，本次登录未保存。请重新打开窗口登录。",
    login_timed_out: "专用登录等待超时，请重新打开窗口完成登录。",
    login_browser_unavailable: "无法启动专用 Chrome 窗口，请确认 Google Chrome 已安装并可正常启动。",
    login_cleanup_failed: "尚未确认专用 Chrome 窗口已关闭。请手动关闭该专用窗口，再退出并重新打开播放器；不要强制结束日常 Chrome。",
    login_settings_unavailable: "无法读取登录方式设置，请检查本机存储后刷新。",
    login_mode_invalid: "登录方式无效，请重新选择并保存。",
    login_mode_required: "请先保存为专用登录方式，再打开登录窗口。",
    login_request_invalid: "登录请求无效，请重新打开下载中心后再试。",
    login_refresh_new_task: "请完成并保存专用登录，然后从原链接新建任务；旧任务不会自动换用新的身份。"
  });
  const MAX_RESPONSE_BYTES = 16 * 1024;
  const REQUEST_TIMEOUT_MS = 15000;
  const POLL_MS = 1500;
  const legacyRows = [originalCookies.closest(".switch-row"),
    originalProfile.closest(".field-label"), document.querySelector("#chrome-profile-help")].filter(Boolean);
  let saved = null;
  let busy = false;
  let disposed = false;
  let generation = 0;
  let request = null;
  let poll = null;
  let requestTimeout = null;
  let message = "正在读取下载登录状态…";
  let failed = false;

  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text) element.textContent = text;
    return element;
  }

  function button(id, text) {
    const element = node("button", "desktop-login-button", text);
    element.type = "button";
    element.id = id;
    return element;
  }

  const panel = node("section", "desktop-login-panel");
  panel.id = "desktop-login-panel";
  panel.setAttribute("aria-labelledby", "desktop-login-heading");
  const heading = node("h3", "desktop-login-heading", "下载登录");
  heading.id = "desktop-login-heading";
  const introduction = node("p", "desktop-login-note",
    "专用登录不读取日常 Chrome 的资料，不需要为此授予完全磁盘访问权限。首次在独立 Chrome 窗口手动登录，再回到这里保存登录。");
  const modeLabel = node("label", "desktop-login-label", "登录方式");
  modeLabel.htmlFor = "desktop-login-mode";
  const mode = node("select", "desktop-login-select");
  mode.id = "desktop-login-mode";
  mode.setAttribute("aria-describedby", "desktop-login-mode-note desktop-login-status");
  for (const [value, text] of [["dedicated", "专用登录（推荐）"],
    ["chrome", "读取日常 Chrome（旧方式）"], ["anonymous", "不登录（仅公开内容）"]]) {
    const option = node("option", "", text);
    option.value = value;
    mode.append(option);
  }
  const modeNote = node("p", "desktop-login-note");
  modeNote.id = "desktop-login-mode-note";
  const modeActions = node("div", "desktop-login-actions");
  const saveMode = button("desktop-login-save-mode", "保存登录方式");
  const refresh = button("desktop-login-refresh", "刷新状态");
  modeActions.append(saveMode, refresh);
  const status = node("p", "desktop-login-status");
  status.id = "desktop-login-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  const platformList = node("div", "desktop-login-platforms");
  const rows = new Map();
  for (const [platform, title] of Object.entries(PLATFORMS)) {
    const row = node("section", "desktop-login-platform");
    row.dataset.platform = platform;
    const name = node("h4", "desktop-login-platform-name", title);
    name.id = `desktop-login-${platform}-name`;
    row.setAttribute("aria-labelledby", name.id);
    const detail = node("p", "desktop-login-note", "尚未读取");
    detail.id = `desktop-login-${platform}-status`;
    const actions = node("div", "desktop-login-actions");
    const open = button(`desktop-login-${platform}-open`, "打开登录窗口");
    const save = button(`desktop-login-${platform}-save`, "保存登录");
    open.setAttribute("aria-describedby", detail.id);
    save.setAttribute("aria-describedby", detail.id);
    open.addEventListener("click", () => act(platform, "open"));
    save.addEventListener("click", () => act(platform, "save"));
    actions.append(open, save);
    row.append(name, detail, actions);
    if (platform === "youtube") row.append(node("p", "desktop-login-note",
      "Google 可能拒绝在受自动化控制的 Chrome 中登录。若出现此提示，请明确改选旧方式或不登录模式；程序不会绕过网站限制。"));
    platformList.append(row);
    rows.set(platform, { row, detail, open, save });
  }
  const retention = node("p", "desktop-login-note",
    "登录记录仅保存在播放器的本机数据目录，重启或升级不会主动清除。已保存不等于网站已确认登录，过期或验证要求仍需手动处理。切换登录方式或重新保存登录后，请从原链接新建任务；旧任务仍绑定原来的身份。");
  panel.append(heading, introduction, modeLabel, mode, modeNote, modeActions, status, platformList, retention);
  settings.before(panel);

  function blocked() {
    return disposed || document.body.classList.contains("version-blocked");
  }

  function dirty() {
    return saved !== null && mode.value !== saved.mode;
  }

  function active() {
    return saved?.platforms.some((item) => ACTIVE.has(item.status) || item.error_code === "login_cleanup_failed") || false;
  }

  function update() {
    const unavailable = blocked() || busy || !saved || failed || Boolean(settingsSave?.disabled);
    mode.disabled = blocked() || busy || !saved || active() || Boolean(settingsSave?.disabled);
    saveMode.disabled = unavailable || !dirty() || active();
    refresh.disabled = blocked() || busy;
    panel.setAttribute("aria-busy", String(busy));
    const legacy = saved?.mode === "chrome";
    for (const row of legacyRows) row.classList.toggle("desktop-login-legacy-hidden", !legacy);
    platformList.hidden = saved?.mode !== "dedicated";
    if (mode.value === "chrome") {
      modeNote.textContent = "旧方式会读取你选择的日常 Chrome 配置，macOS 可能要求文件访问授权。不会自动授予权限，也不会自动换用其他账号。";
    } else if (mode.value === "anonymous") {
      modeNote.textContent = "明确不使用登录信息，仅尝试网站允许匿名访问的公开内容；可能无法下载或获得登录后的画质。不会从其他方式自动降级到此模式。";
    } else {
      modeNote.textContent = "各平台分别登录。请安装 Google Chrome，并先保存代理设置；专用窗口使用下载中心已保存的网络路线。";
    }
    status.textContent = dirty() && !busy && !failed
      ? "登录方式尚未保存。请点击“保存登录方式”；保存成功会重新载入下载中心，请先保存其他设置。"
      : message;
    status.classList.toggle("is-error", failed);
    for (const [platform, controls] of rows) {
      const item = saved?.platforms.find((value) => value.platform === platform);
      controls.open.disabled = unavailable || dirty() || active() || saved?.mode !== "dedicated";
      controls.save.disabled = unavailable || dirty() || saved?.mode !== "dedicated" || item?.status !== "login_open";
      controls.open.textContent = item?.has_saved_session ? "重新打开登录" : "打开登录窗口";
      const descriptions = {
        idle: item?.has_saved_session ? "已有本地登录记录；网站登录有效性尚未确认。" : "尚未保存登录。",
        opening: "正在打开专用 Chrome 窗口…",
        login_open: "请在专用窗口完成登录，再点击“保存登录”。不要在普通 Chrome 窗口登录。",
        saving: "正在保存本机登录记录…",
        saved: "本地登录已保存；网站是否接受该登录将在下载时确认。",
        error: item?.has_saved_session ? "本次操作失败；仍有先前的本地登录记录。可刷新状态后重试。" : "登录操作未完成，请刷新状态后重试。"
      };
      controls.detail.textContent = item ? (item.status === "error" && item.error_code
        ? ERRORS[item.error_code] + (item.has_saved_session ? " 先前的本地登录记录仍存在。" : "")
        : descriptions[item.status]) : "尚未读取";
      controls.detail.classList.toggle("is-error", item?.status === "error");
    }
  }

  function validate(data) {
    if (!data || typeof data !== "object" || Array.isArray(data) || data.schema_version !== 1 ||
        !MODES.has(data.mode) || !Array.isArray(data.platforms) || data.platforms.length !== rows.size) {
      throw new Error("Invalid login response");
    }
    const seen = new Set();
    const platforms = data.platforms.map((item) => {
      if (!item || !Object.hasOwn(PLATFORMS, item.platform) || seen.has(item.platform) ||
          !STATUSES.has(item.status) || typeof item.has_saved_session !== "boolean" ||
          (item.error_code !== undefined && (typeof item.error_code !== "string" ||
            !/^[a-z][a-z0-9_]{0,79}$/.test(item.error_code)))) throw new Error("Invalid login status");
      seen.add(item.platform);
      // Copy only public state fields. Unknown additions or diagnostic codes
      // never become DOM content, links, file paths, or console output.
      return { platform: item.platform, status: item.status, has_saved_session: item.has_saved_session,
        error_code: Object.hasOwn(ERRORS, item.error_code) ? item.error_code : null };
    });
    return { mode: data.mode, platforms };
  }

  async function readResponse(response, signal) {
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") || "")) {
      throw new Error("Invalid login response");
    }
    const declared = response.headers.get("content-length");
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_RESPONSE_BYTES)) {
      throw new Error("Oversized login response");
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Missing login response");
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let text = "";
    let size = 0;
    let complete = false;
    try {
      while (true) {
        if (signal.aborted) throw new Error("Login request cancelled");
        const chunk = await reader.read();
        if (signal.aborted) throw new Error("Login request cancelled");
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > MAX_RESPONSE_BYTES) throw new Error("Oversized login response");
        text += decoder.decode(chunk.value, { stream: true });
      }
      text += decoder.decode();
      complete = true;
    } finally {
      if (!complete) {
        try { await reader.cancel(); } catch { /* Never expose transport details. */ }
      }
      reader.releaseLock();
    }
    const data = JSON.parse(text);
    if (response.status !== 200) {
      const error = new Error("Login request failed");
      if (typeof data?.detail?.code === "string" && Object.hasOwn(ERRORS, data.detail.code)) error.code = data.detail.code;
      throw error;
    }
    return validate(data);
  }

  function stopPoll() {
    if (poll !== null) clearTimeout(poll);
    poll = null;
  }

  function schedulePoll() {
    stopPoll();
    if (!blocked() && !document.hidden && !busy && !failed && active()) {
      poll = setTimeout(() => { poll = null; exchange(); }, POLL_MS);
    }
  }

  async function exchange(path = "", body = null, reload = false) {
    if (blocked() || busy) return;
    stopPoll();
    busy = true;
    failed = false;
    message = reload ? "正在保存登录方式…" : body === null ? "正在刷新登录状态…" : "正在处理登录操作…";
    const identifier = ++generation;
    const controller = new AbortController();
    request = controller;
    requestTimeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    update();
    try {
      const response = await fetch(`/api/native/login${path}`, {
        method: body === null ? "GET" : reload ? "PUT" : "POST",
        credentials: "same-origin", cache: "no-store", signal: controller.signal,
        headers: body === null ? { Accept: "application/json" } :
          { Accept: "application/json", "Content-Type": "application/json" },
        ...(body === null ? {} : { body: JSON.stringify(body) })
      });
      const data = await readResponse(response, controller.signal);
      if (blocked() || identifier !== generation) return;
      if (reload && data.mode !== body.mode) throw new Error("Unconfirmed login mode");
      const preserveDraft = dirty();
      saved = data;
      if (!preserveDraft || reload) mode.value = saved.mode;
      message = "登录状态已读取。不会自动打开登录窗口，也不会自动读取其他浏览器账号。";
      if (reload) {
        message = "登录方式已保存，正在重新载入…";
        window.location.reload();
      }
    } catch (error) {
      controller.abort();
      if (blocked() || identifier !== generation) return;
      failed = true;
      message = reload ? "登录方式保存未确认，当前页面和输入已保留。请刷新状态核实后再试。" :
        "无法完成登录操作或读取状态。请刷新后重试；若仍失败，请查看脱敏诊断，不要发送 Cookie 或密码。";
      if (Object.hasOwn(ERRORS, error?.code)) message += ` ${ERRORS[error.code]}`;
    } finally {
      if (identifier === generation) {
        clearTimeout(requestTimeout);
        requestTimeout = null;
        request = null;
        busy = false;
        update();
        schedulePoll();
      }
    }
  }

  function act(platform, action) {
    const controls = rows.get(platform);
    if (!controls || controls[action].disabled || blocked() || busy || dirty() || saved?.mode !== "dedicated") return;
    exchange(`/${platform}/${action}`, {});
  }

  function guard(event) {
    let reason = "";
    if (blocked()) reason = "下载组件当前不可用，请完成版本检查或重新打开下载中心。";
    else if (!saved || busy || failed) reason = "尚未核实下载登录方式，请等待或点击“刷新状态”。";
    else if (dirty()) reason = "登录方式尚未保存，请先点击“保存登录方式”，再创建新任务。";
    else if (active()) reason = "专用登录窗口仍在处理，请完成并保存登录后再创建新任务。";
    if (!reason) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    message = reason;
    const formError = document.querySelector("#form-error");
    if (formError) formError.textContent = reason;
    update();
  }

  mode.addEventListener("change", update);
  saveMode.addEventListener("click", () => {
    if (!saveMode.disabled && MODES.has(mode.value)) exchange("/mode", { mode: mode.value }, true);
  });
  refresh.addEventListener("click", () => exchange());
  downloads.addEventListener("submit", guard, true);
  const versionObserver = new MutationObserver(() => {
    if (blocked()) { stopPoll(); request?.abort(); }
    update();
  });
  versionObserver.observe(document.body, { attributes: true, attributeFilter: ["class"] });
  const settingsObserver = new MutationObserver(update);
  if (settingsSave) settingsObserver.observe(settingsSave, { attributes: true, attributeFilter: ["disabled"] });
  function visibilityChanged() {
    if (document.hidden) stopPoll();
    else if (active() && !busy) exchange();
  }
  document.addEventListener("visibilitychange", visibilityChanged);
  window.addEventListener("pagehide", () => {
    disposed = true;
    generation += 1;
    stopPoll();
    clearTimeout(requestTimeout);
    request?.abort();
    versionObserver.disconnect();
    settingsObserver.disconnect();
    document.removeEventListener("visibilitychange", visibilityChanged);
    update();
  }, { once: true });
  update();
  exchange();
})();

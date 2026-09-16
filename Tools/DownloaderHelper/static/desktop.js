"use strict";

(() => {
  const bridge = window.webkit?.messageHandlers?.downloadCenter;
  if (!bridge) return;
  const jobs = new Map();
  const outputs = new Map();
  const expandedFiles = new Set();
  const restoredFileLists = new WeakSet();
  let scheduled = false;
  let closed = false;

  function send(message) {
    if (!document.body.classList.contains("version-blocked")) bridge.postMessage(message);
  }

  window.chengyingDownloadCenter = Object.freeze({
    setDirectory(path) {
      if (typeof path !== "string" || !path.startsWith("/")) return;
      const input = document.querySelector("#download-dir");
      if (!input || input.disabled) return;
      input.value = path;
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
      document.querySelector("#save-settings-button")?.focus();
    }
  });

  const brand = document.querySelector(".brand strong");
  if (brand) brand.textContent = "澄影 · 下载中心";
  const eyebrow = document.querySelector(".eyebrow");
  if (eyebrow) eyebrow.textContent = "原迹完整下载引擎 · 下载后直接播放";
  const directory = document.querySelector("#download-dir");
  if (directory) {
    const chooser = document.createElement("button");
    chooser.type = "button";
    chooser.className = "desktop-folder-button";
    chooser.textContent = "选择文件夹…";
    chooser.addEventListener("click", () => send({ action: "chooseDirectory" }));
    directory.closest(".input-shell")?.after(chooser);
    if (!chooser.isConnected) directory.parentElement.after(chooser);
    const hint = document.createElement("p");
    hint.className = "desktop-note";
    hint.textContent = "更改后请点击保存设置。关闭下载中心窗口不会停止下载；退出播放器会停止任务，已下载文件保留。";
    chooser.after(hint);
  }

  const disposeProxyControls = installProxyControls();

  function installProxyControls() {
    const settingsForm = document.querySelector("#settings-form");
    if (!settingsForm) return () => {};

    function element(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      if (text) node.textContent = text;
      return node;
    }

    const form = element("form", "desktop-proxy-card");
    form.id = "desktop-proxy-form";
    form.setAttribute("aria-labelledby", "desktop-proxy-heading");
    const heading = element("h3", "", "下载代理");
    heading.id = "desktop-proxy-heading";
    const scope = element("p", "desktop-note", "仅用于本 App 的下载请求，不修改 macOS 系统代理。关闭后直接连接，不继承系统代理。");
    const toggleLabel = element("label", "desktop-proxy-toggle");
    const enabled = element("input");
    enabled.type = "checkbox";
    enabled.id = "desktop-proxy-enabled";
    enabled.setAttribute("role", "switch");
    toggleLabel.htmlFor = enabled.id;
    toggleLabel.append(enabled, element("span", "", "启用下载代理"));
    const addressLabel = element("label", "desktop-proxy-address-label", "代理地址");
    addressLabel.htmlFor = "desktop-proxy-url";
    const address = element("input", "desktop-proxy-address");
    address.id = "desktop-proxy-url";
    address.type = "password";
    address.autocomplete = "off";
    address.spellcheck = false;
    address.autocapitalize = "off";
    address.placeholder = "输入完整代理地址；留空保留已保存地址";
    address.setAttribute("aria-describedby", "desktop-proxy-examples desktop-proxy-saved desktop-proxy-privacy");
    const examples = element("p", "desktop-note desktop-proxy-examples");
    examples.id = "desktop-proxy-examples";
    examples.append("支持 ", element("code", "", "http://127.0.0.1:7897"), "、",
      element("code", "", "socks5://127.0.0.1:7897"), " 或 ", element("code", "", "https://代理主机:端口"), "。");
    const savedLabel = element("p", "desktop-note desktop-proxy-saved", "正在读取已保存的代理…");
    savedLabel.id = "desktop-proxy-saved";
    const protocolHint = element("p", "desktop-note", "这里的协议是代理服务的协议，不是视频网站的协议：HTTP 代理也能连接 HTTPS 视频网站。请按你的代理软件提供的入口填写。");
    const privacy = element("p", "desktop-note", "只使用你信任的代理。HTTP / HTTPS 支持 ASCII 用户名和密码；SOCKS5 不支持认证，可改用本地 HTTP 入口。地址按密码遮挡，已保存的密码不会回显。");
    privacy.id = "desktop-proxy-privacy";
    const timing = element("p", "desktop-note", "更改后单独点击“保存代理”。正在解析、下载或后处理时，请先取消任务或等待完成，再保存代理。");
    const actions = element("div", "desktop-proxy-actions");
    const save = element("button", "desktop-proxy-primary", "保存代理");
    save.id = "desktop-proxy-save";
    save.type = "submit";
    const test = element("button", "", "测试连接");
    test.id = "desktop-proxy-test";
    test.type = "button";
    const clear = element("button", "", "清除代理");
    clear.id = "desktop-proxy-clear";
    clear.type = "button";
    const retry = element("button", "", "重新读取代理设置");
    retry.id = "desktop-proxy-retry";
    retry.type = "button";
    actions.append(save, test, clear, retry);
    const status = element("p", "desktop-proxy-status", "正在读取代理设置…");
    status.id = "desktop-proxy-status";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    const testHint = element("p", "desktop-note", "测试会用输入的地址（留空则用已保存地址）连接 YouTube 的公开 HTTPS 检测地址，不发送 Cookie，也不保存设置。仅用于出网诊断，连接成功不代表所有视频网站、账号或下载权限一定可用。");
    form.append(heading, scope, toggleLabel, addressLabel, address, examples, savedLabel,
      protocolHint, privacy, timing, actions, status, testHint);
    settingsForm.after(form);

    const messages = Object.freeze({
      invalid_proxy: "代理地址无效。请填写完整的 HTTP、HTTPS 或 SOCKS5 地址及正确端口，不要附带路径、查询参数或片段。",
      socks_auth_unsupported: "当前 SOCKS5 入口不支持用户名或密码认证，请改用代理软件提供的本地 HTTP 入口。",
      proxy_auth_unsupported: "HTTP / HTTPS 代理用户名和密码需使用 ASCII 字符（英文、数字、符号），以确保浏览器和下载器使用一致的认证编码。也可改用本地代理入口。",
      proxy_not_configured: "请先输入代理地址，或保存一个代理地址后再启用或测试。",
      proxy_busy: "目前仍有解析、下载或后处理任务。请先取消任务或等待完成，再保存代理。",
      proxy_save_failed: "代理设置保存失败。当前输入已保留，请检查本机存储权限后重试。",
      proxy_unavailable: "暂时无法连接下载组件。当前输入已保留，请重新读取设置后重试。",
      proxy_timeout: "代理操作超过 30 秒仍未完成，已停止等待。当前输入已保留，请重新读取设置或稍后重试。",
      proxy_test_failed: "代理连接测试失败。请检查代理软件是否运行、地址和端口是否正确，以及代理能否访问 HTTPS 站点。",
      proxy_test_busy: "已有代理连接测试正在进行，请稍后再试。",
      proxy_settings_unreadable: "无法读取已保存的代理设置，已暂停更改以避免覆盖。请修复本机设置文件或重新读取后再试。"
    });
    let loaded = false;
    let busy = false;
    let draftChanged = false;
    let allowCorruptReset = false;
    let saved = null;
    let requestController = null;
    let disposed = false;
    const controls = [enabled, address, save, test, clear];

    function blocked() {
      return disposed || closed || document.body.classList.contains("version-blocked");
    }

    function updateControls() {
      const unavailable = blocked() || busy || !loaded;
      controls.forEach((control) => { control.disabled = unavailable; });
      clear.disabled = blocked() || busy || (!allowCorruptReset && (!loaded || !saved?.configured));
      clear.textContent = allowCorruptReset ? "清除损坏的代理设置" : "清除代理";
      retry.hidden = loaded;
      retry.disabled = blocked() || busy;
      form.setAttribute("aria-busy", busy ? "true" : "false");
    }

    function setStatus(text, isError = false) {
      if (disposed || closed) return;
      status.textContent = text;
      status.classList.toggle("is-error", isError);
    }

    function readState(data) {
      if (!data || typeof data.enabled !== "boolean" || typeof data.configured !== "boolean"
        || typeof data.display_url !== "string" || typeof data.has_credentials !== "boolean") {
        throw new Error("proxy_settings_unreadable");
      }
      let display = "";
      if (data.configured) {
        try {
          // Never render authentication or a server-provided raw URL.
          const url = new URL(data.display_url);
          if (!["http:", "https:", "socks5:"].includes(url.protocol) || !url.hostname) throw new Error();
          display = `${url.protocol}//${url.host}`;
        } catch { throw new Error("proxy_settings_unreadable"); }
      }
      if (data.enabled && !data.configured) throw new Error("proxy_settings_unreadable");
      return { enabled: data.enabled, configured: data.configured, display, hasCredentials: data.has_credentials };
    }

    function showSavedState() {
      savedLabel.textContent = saved.configured
        ? `已保存：${saved.display}（${saved.enabled ? "已启用" : "未启用，当前直连"}）${saved.hasCredentials ? "；含已保存的认证信息，不回显。留空保存会保留认证。" : "；留空保存会保留此地址。"}`
        : "尚未保存代理，当前直接连接。";
    }

    function inputURL() {
      const value = address.value.trim();
      if (!value) return undefined;
      try {
        const url = new URL(value);
        if (!["http:", "https:", "socks5:"].includes(url.protocol) || !url.hostname
          || /[\s\\]/.test(value) || (url.pathname && url.pathname !== "/") || url.search || url.hash) {
          throw new Error("invalid_proxy");
        }
        if (url.protocol === "socks5:" && (url.username || url.password)) throw new Error("socks_auth_unsupported");
      } catch (error) {
        if (error.message === "socks_auth_unsupported") throw error;
        throw new Error("invalid_proxy");
      }
      return value;
    }

    async function request(method, path, body) {
      requestController = new AbortController();
      const controller = requestController;
      let timedOut = false;
      const timeout = setTimeout(() => { timedOut = true; controller.abort(); }, 30000);
      try {
        const response = await fetch(path, {
          method, cache: "no-store", credentials: "same-origin", signal: controller.signal,
          ...(body ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {})
        });
        let data;
        try { data = await response.json(); } catch { throw new Error("proxy_unavailable"); }
        if (!response.ok) {
          const code = data?.detail?.code;
          const error = new Error(Object.hasOwn(messages, code) ? code : "proxy_unavailable");
          error.allowProxyReset = method === "GET" && response.status === 503 && code === "proxy_settings_unreadable";
          throw error;
        }
        return data;
      } catch (error) {
        if (timedOut) throw new Error("proxy_timeout");
        throw error;
      } finally {
        clearTimeout(timeout);
      }
    }

    function showFailure(error, operation) {
      if (blocked()) return;
      const code = Object.hasOwn(messages, error?.message) ? error.message : "proxy_unavailable";
      if (error?.allowProxyReset === true) allowCorruptReset = true;
      if (code === "proxy_settings_unreadable" || (operation !== "test" && ["proxy_unavailable", "proxy_timeout"].includes(code))) {
        // An interrupted save may have succeeded. Re-read before another write.
        loaded = false;
      }
      setStatus(messages[code] + (allowCorruptReset ? "也可点击“清除损坏的代理设置”，确认后清除地址及认证信息并恢复直连。" : ""), true);
    }

    async function load() {
      if (busy || blocked()) return;
      busy = true;
      updateControls();
      setStatus("正在读取代理设置…");
      try {
        const data = await request("GET", "/api/native/proxy");
        if (blocked()) return;
        saved = readState(data);
        loaded = true;
        allowCorruptReset = false;
        if (!draftChanged) enabled.checked = saved.enabled;
        showSavedState();
        setStatus(draftChanged ? "设置已重新读取；未保存的输入仍然保留。" : "代理设置已读取。更改后请单独保存代理。");
      } catch (error) {
        loaded = false;
        showFailure(error, "load");
      } finally {
        requestController = null;
        busy = false;
        updateControls();
      }
    }

    async function perform(operation) {
      if (busy || blocked() || (!loaded && !(operation === "clear" && allowCorruptReset))) return;
      if (operation === "clear" && allowCorruptReset) {
        if (!window.confirm("本地代理设置已损坏。确定清除已保存的代理地址和认证信息，并恢复直接连接吗？")) return;
        if (busy || blocked()) return;
      }
      const originalInput = address.value;
      const originalEnabled = enabled.checked;
      let body;
      try {
        if (operation === "clear") body = { enabled: false, url: "" };
        else {
          const url = inputURL();
          body = { enabled: operation === "test" ? true : originalEnabled };
          if (url !== undefined) body.url = url;
          if (body.enabled && !url && !saved.configured) throw new Error("proxy_not_configured");
        }
      } catch (error) {
        showFailure(error, operation);
        return;
      }
      busy = true;
      updateControls();
      setStatus(operation === "test" ? "正在通过代理测试 HTTPS 连接…" : "正在保存代理设置…");
      try {
        const data = await request(operation === "test" ? "POST" : "PUT",
          operation === "test" ? "/api/native/proxy/test" : "/api/native/proxy", body);
        if (blocked()) return;
        if (operation === "test") {
          if (data?.ok !== true) {
            throw new Error(Object.hasOwn(messages, data?.code) ? data.code : "proxy_test_failed");
          }
          const elapsed = Number.isFinite(data.elapsed_ms) && data.elapsed_ms >= 0
            ? `（${(data.elapsed_ms / 1000).toFixed(2)} 秒）` : "";
          setStatus(`代理 HTTPS 连接成功${elapsed}。测试未保存设置；视频网站、账号或下载权限仍需实际下载确认。`);
        } else {
          saved = readState(data);
          loaded = true;
          allowCorruptReset = false;
          showSavedState();
          if (address.value === originalInput && enabled.checked === originalEnabled) {
            address.value = "";
            enabled.checked = saved.enabled;
            draftChanged = false;
          }
          setStatus(operation === "clear" ? "代理地址及认证信息已清除，之后的下载直接连接。"
            : saved.enabled ? "下载代理已保存并启用，仅影响本 App。" : "下载代理已关闭，之后的下载直接连接；已保存地址保留。");
        }
      } catch (error) {
        showFailure(error, operation);
      } finally {
        requestController = null;
        busy = false;
        updateControls();
      }
    }

    address.addEventListener("input", () => { draftChanged = true; });
    enabled.addEventListener("change", () => { draftChanged = true; });
    form.addEventListener("submit", (event) => { event.preventDefault(); perform("save"); });
    test.addEventListener("click", () => perform("test"));
    clear.addEventListener("click", () => perform("clear"));
    retry.addEventListener("click", load);
    const versionObserver = new MutationObserver(() => {
      if (blocked()) requestController?.abort();
      updateControls();
    });
    versionObserver.observe(document.body, { attributes: true, attributeFilter: ["class"] });
    updateControls();
    load();

    return () => {
      disposed = true;
      address.value = "";
      requestController?.abort();
      versionObserver.disconnect();
      updateControls();
    };
  }

  function scheduleDecoration() {
    if (scheduled || closed) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      decorateFiles();
      const alert = document.querySelector("#version-alert-detail");
      if (alert && /start\.command|Terminal/.test(alert.textContent)) {
        alert.textContent = "下载组件版本不一致。请退出澄影播放器后重新打开，任务记录与已下载文件会保留。";
      }
    });
  }

  function decorateFiles() {
    // The preserved frontend replaces result rows during polling and SSE updates.
    // Keep user-expanded file lists open without changing its rendering pipeline.
    document.querySelectorAll(".item-files").forEach((files) => {
      if (restoredFileLists.has(files)) return;
      const key = fileListKey(files);
      if (!key) return;
      restoredFileLists.add(files);
      if (key && expandedFiles.has(key) && !files.open) files.open = true;
    });
    document.querySelectorAll(".item-files li[title]").forEach((entry) => {
      if (entry.querySelector(".desktop-output-actions")) return;
      const path = entry.title;
      const record = outputs.get(path);
      if (!record) return;
      const actions = document.createElement("span");
      actions.className = "desktop-output-actions";
      function button(label, action) {
        const control = document.createElement("button");
        control.type = "button";
        control.textContent = label;
        control.setAttribute("aria-label", `${label}：${entry.textContent}`);
        control.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          const current = outputs.get(path);
          if (current) send({ action, ...current });
        });
        actions.append(control);
      }
      if (/\.(mp4|m4v|mov|mkv|webm|avi|ts|m2ts|flv|mts|3gp|mpeg|mpg|ogv)$/i.test(path)) button("播放", "play");
      if (/\.(jpe?g|png|webp|gif|heic|heif|avif|bmp|tiff?)$/i.test(path)) button("查看", "play");
      button("在 Finder 中显示", "reveal");
      entry.append(actions);
    });
  }

  function fileListKey(files) {
    const paths = Array.from(files.querySelectorAll("li[title]"), (entry) => entry.title);
    return paths.length ? JSON.stringify(paths) : null;
  }

  function rememberFileDisclosure(event) {
    const files = event.target;
    if (!(files instanceof HTMLDetailsElement) || !files.matches(".item-files") || !files.isConnected) return;
    const key = fileListKey(files);
    if (!key) return;
    restoredFileLists.add(files);
    if (files.open) expandedFiles.add(key);
    else expandedFiles.delete(key);
  }

  document.addEventListener("toggle", rememberFileDisclosure, true);

  function acceptJob(job) {
    if (!job || typeof job.id !== "string" || !Array.isArray(job.items)) return;
    const previous = jobs.get(job.id);
    if (previous && Number(previous.revision) > Number(job.revision)) return;
    jobs.set(job.id, job);
    outputs.clear();
    for (const current of jobs.values()) {
      for (const item of current.items) {
        if (item.status !== "completed" || !Array.isArray(item.output_paths)) continue;
        item.output_paths.forEach((path, index) => {
          if (typeof path === "string") outputs.set(path, { jobID: current.id, itemID: item.id, index });
        });
      }
    }
    scheduleDecoration();
  }

  async function refreshOutputs() {
    try {
      const response = await fetch("/api/jobs", { cache: "no-store" });
      if (!response.ok || closed) return;
      const data = await response.json();
      if (Array.isArray(data)) data.forEach(acceptJob);
    } catch { /* The original UI already reports connection failures. */ }
  }

  const observer = new MutationObserver(scheduleDecoration);
  observer.observe(document.querySelector("#main-content") || document.body, { childList: true, subtree: true });
  // A separate read-only subscription avoids altering the proven frontend's
  // private state, event handling, cancellation, and retry implementations.
  const events = new EventSource("/api/events");
  events.addEventListener("job", (event) => {
    try { acceptJob(JSON.parse(event.data)); } catch { /* Ignore malformed events. */ }
  });
  events.addEventListener("open", refreshOutputs);
  refreshOutputs();

  fetch("/api/native/status", { cache: "no-store" })
    .then((response) => response.ok ? response.json() : null)
    .then((status) => {
      if (!status || status.chrome_installed) return;
      const notice = document.createElement("p");
      notice.className = "desktop-chrome-notice";
      notice.setAttribute("role", "status");
      notice.textContent = "未检测到 Google Chrome。小红书、抖音和使用 Chrome 登录态的下载需要先安装 Chrome，并在其中登录对应网站。Cookie 只在本机用于对应网站的请求，不会随项目上传；验证仍会打开原任务绑定的 Chrome 账号。";
      document.querySelector(".hero")?.prepend(notice);
    })
    .catch(() => {});

  window.addEventListener("pagehide", () => {
    closed = true;
    disposeProxyControls();
    events.close();
    observer.disconnect();
    document.removeEventListener("toggle", rememberFileDisclosure, true);
  }, { once: true });
})();

"use strict";

(() => {
  if (document.querySelector("#desktop-diagnostics-entry")) return;

  const MAX_REPORT_BYTES = 64 * 1024;
  const MAX_RESPONSE_BYTES = 512 * 1024;
  const REQUEST_TIMEOUT_MS = 10000;
  const endpoint = "/api/native/diagnostics";
  let generation = 0;
  let controller = null;
  let timeout = null;
  let loading = false;
  let copying = false;
  let disposed = false;
  let reportText = "";

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function button(id, text) {
    const node = element("button", "desktop-diagnostics-button", text);
    node.id = id;
    node.type = "button";
    return node;
  }

  const entry = element("div", "desktop-diagnostics-entry");
  entry.id = "desktop-diagnostics-entry";
  const open = button("desktop-diagnostics-open", "诊断日志");
  open.setAttribute("aria-controls", "desktop-diagnostics-panel");
  open.setAttribute("aria-expanded", "false");
  const entryHint = element("span", "desktop-diagnostics-note", "下载出错时，可查看并复制脱敏诊断日志。");
  entry.append(open, entryHint);

  const panel = element("section", "desktop-diagnostics-panel");
  panel.id = "desktop-diagnostics-panel";
  panel.hidden = true;
  panel.setAttribute("aria-labelledby", "desktop-diagnostics-heading");
  const heading = element("h3", "", "诊断日志");
  heading.id = "desktop-diagnostics-heading";
  const scope = element("p", "desktop-diagnostics-note", "范围：最近最多 10 个任务的脱敏诊断，不限于当前选中的任务。");
  scope.id = "desktop-diagnostics-scope";
  const privacy = element("p", "desktop-diagnostics-note", "仅在本机读取。诊断内容为英文，便于排查；不会自动复制、上传或保存文件。请在复现问题后、退出软件前复制；重启会清空本次过程记录。");
  const label = element("label", "desktop-diagnostics-label", "可选中的诊断文本");
  label.htmlFor = "desktop-diagnostics-text";
  const text = element("textarea", "desktop-diagnostics-text");
  text.id = "desktop-diagnostics-text";
  text.readOnly = true;
  text.spellcheck = false;
  text.rows = 14;
  text.setAttribute("aria-describedby", "desktop-diagnostics-scope desktop-diagnostics-status");
  const actions = element("div", "desktop-diagnostics-actions");
  const refresh = button("desktop-diagnostics-refresh", "刷新");
  const copy = button("desktop-diagnostics-copy", "复制诊断日志");
  copy.classList.add("desktop-diagnostics-primary");
  const close = button("desktop-diagnostics-close", "关闭");
  actions.append(refresh, copy, close);
  const status = element("p", "desktop-diagnostics-status", "点击刷新读取诊断日志。");
  status.id = "desktop-diagnostics-status";
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  panel.append(heading, scope, privacy, label, text, actions, status);
  const hero = document.querySelector(".hero");
  if (hero) hero.after(entry);
  else document.body.prepend(entry);
  entry.after(panel);

  function blocked() {
    return document.body.classList.contains("version-blocked");
  }

  function available() {
    return !disposed && !panel.hidden && !blocked();
  }

  function current(identifier) {
    return identifier === generation && available();
  }

  function updateControls() {
    open.disabled = disposed || blocked();
    refresh.disabled = !available() || loading || copying;
    copy.disabled = !available() || loading || copying || !reportText;
    panel.setAttribute("aria-busy", String(loading || copying));
  }

  function cancelPending() {
    generation += 1;
    controller?.abort();
    controller = null;
    if (timeout !== null) clearTimeout(timeout);
    timeout = null;
    loading = false;
    copying = false;
  }

  function clearReport() {
    reportText = "";
    text.value = "";
  }

  async function readReport(response, signal) {
    if (response.status !== 200 ||
        !/^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") || "")) {
      throw new Error("Invalid diagnostic response");
    }
    const declared = response.headers.get("content-length");
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_RESPONSE_BYTES)) {
      throw new Error("Oversized diagnostic response");
    }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Missing diagnostic response body");
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let size = 0;
    let json = "";
    let completed = false;
    try {
      while (true) {
        if (signal.aborted) throw new Error("Diagnostic request cancelled");
        const chunk = await reader.read();
        if (signal.aborted) throw new Error("Diagnostic request cancelled");
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > MAX_RESPONSE_BYTES) throw new Error("Oversized diagnostic response");
        json += decoder.decode(chunk.value, { stream: true });
      }
      json += decoder.decode();
      completed = true;
    } finally {
      if (!completed) {
        try { await reader.cancel(); } catch { /* Cancellation must not disclose transport errors. */ }
      }
      reader.releaseLock();
    }
    const payload = JSON.parse(json);
    if (!payload || typeof payload !== "object" || Array.isArray(payload) ||
        payload.schema_version !== 1 || typeof payload.text !== "string" ||
        !payload.text.trim() || payload.text.length > MAX_REPORT_BYTES ||
        new TextEncoder().encode(payload.text).byteLength > MAX_REPORT_BYTES) {
      throw new Error("Invalid diagnostic report");
    }
    return payload.text;
  }

  async function loadReport() {
    if (!available() || loading || copying) return;
    cancelPending();
    clearReport();
    const identifier = generation;
    const request = new AbortController();
    controller = request;
    loading = true;
    status.textContent = "正在读取脱敏诊断日志…";
    updateControls();
    timeout = setTimeout(() => {
      if (!current(identifier)) return;
      cancelPending();
      status.textContent = "读取诊断日志超时，请重试。";
      updateControls();
    }, REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(endpoint, {
        method: "GET", credentials: "same-origin", cache: "no-store",
        headers: { Accept: "application/json" }, signal: request.signal,
      });
      if (!current(identifier)) return;
      const value = await readReport(response, request.signal);
      if (!current(identifier)) return;
      reportText = value;
      text.value = value;
      status.textContent = "日志已就绪。可点击“复制诊断日志”，或选中文本后按 Command+C。";
    } catch {
      request.abort();
      if (!current(identifier)) return;
      clearReport();
      status.textContent = "无法读取诊断日志，请稍后重试。";
    } finally {
      if (current(identifier)) {
        if (timeout !== null) clearTimeout(timeout);
        timeout = null;
        controller = null;
        loading = false;
        updateControls();
      }
    }
  }

  async function copyReport() {
    if (!available() || loading || copying || !reportText) return;
    const identifier = generation;
    copying = true;
    status.textContent = "正在复制诊断日志…";
    updateControls();
    let copied = false;
    try {
      if (typeof navigator.clipboard?.writeText === "function") {
        // Keep this call inside the user's second click, after loading finishes.
        await navigator.clipboard.writeText(reportText);
        copied = true;
      }
    } catch { /* Fall back to the visible, selectable report without exposing errors. */ }
    if (!current(identifier)) return;
    if (!copied) {
      text.value = reportText;
      text.focus();
      text.select();
      if (!current(identifier)) return;
      try {
        copied = typeof document.execCommand === "function" && document.execCommand("copy") === true;
      } catch { /* The selected text remains available for Command+C. */ }
    }
    if (!current(identifier)) return;
    copying = false;
    status.textContent = copied
      ? "诊断日志已复制。请粘贴到你要发送的位置。"
      : "系统未允许自动复制，已选中日志文本，请按 Command+C 复制。";
    updateControls();
  }

  open.addEventListener("click", () => {
    if (disposed || blocked()) return;
    if (!panel.hidden) {
      text.focus();
      return;
    }
    panel.hidden = false;
    open.setAttribute("aria-expanded", "true");
    text.focus();
    loadReport();
  });
  refresh.addEventListener("click", loadReport);
  copy.addEventListener("click", copyReport);
  close.addEventListener("click", () => {
    cancelPending();
    clearReport();
    panel.hidden = true;
    open.setAttribute("aria-expanded", "false");
    updateControls();
    if (!disposed) open.focus();
  });

  const observer = new MutationObserver(() => {
    if (blocked()) {
      cancelPending();
      clearReport();
      status.textContent = "下载组件版本不一致，请退出播放器后重新打开。";
    }
    updateControls();
  });
  observer.observe(document.body, { attributes: true, attributeFilter: ["class"] });
  window.addEventListener("pagehide", () => {
    disposed = true;
    cancelPending();
    clearReport();
    updateControls();
    observer.disconnect();
  }, { once: true });
  updateControls();
})();

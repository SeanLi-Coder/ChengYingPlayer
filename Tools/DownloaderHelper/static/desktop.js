"use strict";

(() => {
  const bridge = window.webkit?.messageHandlers?.downloadCenter;
  if (!bridge) return;
  const jobs = new Map();
  const outputs = new Map();
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
      button("在 Finder 中显示", "reveal");
      entry.append(actions);
    });
  }

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
    events.close();
    observer.disconnect();
  }, { once: true });
})();

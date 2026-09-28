// Exercise the production diagnostic panel without network, browser, or clipboard access.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../DownloaderHelper/static/diagnostics.js", import.meta.url), "utf8");
let checks = 0;
function check(condition, message) {
  assert(condition, message);
  checks += 1;
}
const settle = async () => { for (let index = 0; index < 24; index += 1) await Promise.resolve(); };
const safeReport = "ChengYing download diagnostics\nSchema: 1\nIssue: cookie_unavailable\n";
const privateMarker = "DO_NOT_DISCLOSE_PRIVATE_FIXTURE";

class Element {
  constructor(tag, document) {
    this.tagName = tag;
    this.document = document;
    this.children = [];
    this.listeners = new Map();
    this.attributes = new Map();
    this.value = "";
    this.disabled = false;
    this.hidden = false;
    this.className = "";
    const classes = new Set();
    this.classList = {
      contains: (name) => classes.has(name) || this.className.split(/\s+/).includes(name),
      add: (name) => classes.add(name), remove: (name) => classes.delete(name),
    };
  }
  append(...nodes) {
    this.children.push(...nodes);
    nodes.forEach((node) => { node.parentElement = this; });
  }
  prepend(node) { this.children.unshift(node); node.parentElement = this; }
  after(node) {
    const children = this.parentElement.children;
    children.splice(children.indexOf(this) + 1, 0, node);
    node.parentElement = this.parentElement;
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text || this.children.map((node) => node.textContent).join(""); }
  set innerHTML(_) { throw new Error("Diagnostic markup must not use innerHTML"); }
  setAttribute(name, value) { this.attributes.set(name, value); }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  click() { return this.listeners.get("click")?.(); }
  focus() { this.document.activeElement = this; }
  select() { this.document.selected = this; this.document.onSelect?.(); }
  find(selector) {
    if (selector.startsWith("#") && this.id === selector.slice(1)) return this;
    if (selector.startsWith(".") && this.classList.contains(selector.slice(1))) return this;
    for (const child of this.children) {
      const found = child.find(selector);
      if (found) return found;
    }
    return null;
  }
}

function fixture({ clipboard = "success", fallback = true, blocked = false, hero = true } = {}) {
  const document = {};
  const body = new Element("body", document);
  document.body = body;
  if (blocked) body.classList.add("version-blocked");
  if (hero) {
    const heading = new Element("section", document);
    heading.className = "hero";
    body.append(heading);
  }
  document.createElement = (tag) => new Element(tag, document);
  document.querySelector = (selector) => body.find(selector);
  const copied = [];
  const fallbackCalls = [];
  document.execCommand = (command) => {
    fallbackCalls.push({ command, text: document.selected?.value });
    if (fallback === "throw") throw new Error(privateMarker);
    return fallback;
  };
  let clipboardFinish;
  const navigator = clipboard === "missing" ? {} : {
    clipboard: {
      writeText(value) {
        copied.push(value);
        if (clipboard === "failure") return Promise.reject(new Error(privateMarker));
        if (clipboard === "pending") return new Promise((resolve, reject) => { clipboardFinish = { resolve, reject }; });
        return Promise.resolve();
      },
    },
  };
  const observers = [];
  const timers = new Map();
  const windowEvents = new Map();
  const calls = [];
  let timerID = 0;
  const context = vm.createContext({
    document, navigator, TextEncoder, TextDecoder, Uint8Array, AbortController,
    window: { addEventListener: (name, callback) => windowEvents.set(name, callback) },
    setTimeout(callback) { timerID += 1; timers.set(timerID, callback); return timerID; },
    clearTimeout(id) { timers.delete(id); },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; observers.push(this); }
      observe() {}
      disconnect() { this.disconnected = true; }
    },
    fetch(path, options) {
      return new Promise((resolve, reject) => {
        const call = {
          path, options, aborted: false, ignoreAbort: false, cancelled: false, released: false,
          reject,
          reply(payload, { status = 200, contentType = "application/json", contentLength = null,
                           raw, chunks, body = true, read } = {}) {
            const bytes = new TextEncoder().encode(raw ?? JSON.stringify(payload));
            const parts = chunks ?? [bytes.subarray(0, 7), bytes.subarray(7)];
            let cursor = 0;
            resolve({
              status,
              headers: { get: (name) => name === "content-type" ? contentType : contentLength },
              body: body ? {
                getReader() {
                  return {
                    read: read ?? (async () => cursor < parts.length
                      ? { done: false, value: parts[cursor++] } : { done: true }),
                    async cancel() { call.cancelled = true; },
                    releaseLock() { call.released = true; },
                  };
                },
              } : null,
            });
          },
        };
        options.signal.addEventListener("abort", () => {
          call.aborted = true;
          if (!call.ignoreAbort) reject(new Error(privateMarker));
        }, { once: true });
        calls.push(call);
      });
    },
  });
  vm.runInContext(source, context);
  return {
    body, document, calls, copied, fallbackCalls, timers, observers,
    node: (suffix) => document.querySelector(`#desktop-diagnostics-${suffix}`),
    reload: () => vm.runInContext(source, context),
    pagehide: () => windowEvents.get("pagehide")(),
    versionBlocked() {
      body.classList.add("version-blocked");
      observers.forEach((observer) => observer.callback());
    },
    expire() {
      [...timers].forEach(([id, callback]) => { timers.delete(id); callback(); });
    },
    finishCopy: () => clipboardFinish,
  };
}

async function ready(options = {}, report = safeReport) {
  const view = fixture(options);
  view.node("open").click();
  view.calls[0].reply({ schema_version: 1, text: report });
  await settle();
  return view;
}

{
  const view = fixture();
  check(view.calls.length === 0 && view.copied.length === 0, "Creating the panel neither fetches nor copies");
  check(view.node("panel").hidden && view.node("copy").disabled, "The closed panel cannot copy");
  check(view.node("scope").textContent.includes("10") && view.node("scope").textContent.includes("不限于"), "The recent-task scope is explicit");
  view.reload();
  check(view.observers.length === 1, "Duplicate script installation leaves one panel and observer");
  view.node("open").click();
  view.node("open").click();
  view.node("refresh").click();
  view.node("copy").click();
  check(view.calls.length === 1 && view.copied.length === 0, "Repeated clicks cannot race loading or copy an unfinished report");
  const { path, options } = view.calls[0];
  check(path === "/api/native/diagnostics" && options.method === "GET" && !options.body, "Only the read-only diagnostic endpoint is requested");
  check(options.credentials === "same-origin" && options.cache === "no-store" && options.headers.Accept === "application/json", "Requests retain authenticated no-store behavior");
  view.calls[0].reply({ schema_version: 1, text: safeReport });
  await settle();
  check(view.node("text").readOnly && view.node("text").value === safeReport && !view.node("copy").disabled, "A valid report is visible and selectable before copying");
  check(view.copied.length === 0 && view.timers.size === 0, "Loading never writes the clipboard and clears its timeout");
  await view.node("copy").click();
  check(view.copied[0] === safeReport && view.fallbackCalls.length === 0, "A separate click invokes the Clipboard API with only the report");
  check(view.node("status").textContent.includes("已复制"), "Successful copying is reported after completion");
}

for (const clipboard of ["failure", "missing"]) {
  const view = await ready({ clipboard });
  await view.node("copy").click();
  check(view.fallbackCalls.length === 1 && view.fallbackCalls[0].command === "copy" &&
    view.fallbackCalls[0].text === safeReport, "Clipboard denial or absence falls back to the selected report");
  check(view.node("status").textContent.includes("已复制") && !view.body.textContent.includes(privateMarker), "Fallback success never displays a raw exception");
}

for (const fallback of [false, "throw"]) {
  const view = await ready({ clipboard: "failure", fallback });
  await view.node("copy").click();
  check(view.document.selected === view.node("text") && view.node("status").textContent.includes("Command+C"), "Denied fallback keeps the report selected for manual copying");
  check(!view.body.textContent.includes(privateMarker), "Manual-copy guidance hides transport and clipboard errors");
}

{
  const literal = "<img src=x onerror=alert(1)>\n" + safeReport;
  const view = await ready({}, literal);
  check(view.node("text").value === literal && view.node("text").children.length === 0, "Report text is never interpreted as markup");
  view.node("refresh").click();
  check(view.node("text").value === "" && view.node("copy").disabled && view.calls.length === 2, "Refreshing invalidates the previous report");
  view.calls[1].reject(new Error(privateMarker));
  await settle();
  check(view.node("status").textContent === "无法读取诊断日志，请稍后重试。" && !view.body.textContent.includes(privateMarker), "Failed requests show only fixed guidance");
}

for (const malformed of [
  null, [], { schema_version: "1", text: safeReport }, { schema_version: 2, text: safeReport },
  { schema_version: 1, text: 123 }, { schema_version: 1, text: "" },
  { schema_version: 1, text: "x".repeat(65537) },
  { schema_version: 1, text: "中".repeat(22000) },
]) {
  const view = fixture();
  view.node("open").click();
  view.calls[0].reply(malformed);
  await settle();
  check(view.node("text").value === "" && view.node("copy").disabled &&
    view.node("status").textContent === "无法读取诊断日志，请稍后重试。", "Invalid schemas, types, and UTF-8 report sizes cannot be copied");
}

for (const response of [
  { status: 503 }, { contentType: "text/html" }, { contentLength: "524289" },
  { contentLength: "invalid" }, { body: false }, { raw: "not JSON" },
  { chunks: [new Uint8Array([0xff])] },
  { chunks: [new Uint8Array(300000), new Uint8Array(300000)] },
]) {
  const view = fixture();
  view.node("open").click();
  view.calls[0].reply({ schema_version: 1, text: safeReport }, response);
  await settle();
  check(view.node("copy").disabled && view.node("text").value === "", "Invalid or oversized HTTP bodies fail closed");
}

{
  const view = await ready({}, "x".repeat(65536));
  check(view.node("text").value.length === 65536 && !view.node("copy").disabled, "A report at the exact 64 KiB boundary remains valid");
}

for (const action of ["close", "pagehide", "version"]) {
  const view = fixture();
  view.node("open").click();
  view.calls[0].ignoreAbort = true;
  if (action === "close") view.node("close").click();
  else if (action === "pagehide") view.pagehide();
  else view.versionBlocked();
  view.calls[0].reply({ schema_version: 1, text: safeReport });
  await settle();
  check(view.calls[0].aborted && view.node("text").value === "" && view.copied.length === 0, "Closed, disposed, or blocked panels reject late responses");
  if (action === "pagehide") check(view.observers[0].disconnected, "Page disposal releases the mutation observer");
  if (action === "version") check(view.node("open").disabled && view.node("refresh").disabled && view.node("copy").disabled, "Version mismatch disables all diagnostic actions");
}

{
  const view = fixture();
  view.node("open").click();
  view.calls[0].ignoreAbort = true;
  view.expire();
  check(view.calls[0].aborted && !view.node("refresh").disabled && view.node("status").textContent.includes("超时"), "Timeout aborts the request and permits a retry");
  view.node("refresh").click();
  view.calls[0].reply({ schema_version: 1, text: "Stale report" });
  view.calls[1].reply({ schema_version: 1, text: safeReport });
  await settle();
  check(view.node("text").value === safeReport, "A timed-out response cannot replace the retry result");
}

for (const action of ["close", "pagehide", "version"]) {
  const view = await ready({ clipboard: "pending" });
  view.node("copy").click();
  view.node("copy").click();
  check(view.copied.length === 1, "Concurrent copy clicks invoke only one clipboard operation");
  if (action === "close") view.node("close").click();
  else if (action === "pagehide") view.pagehide();
  else view.versionBlocked();
  view.finishCopy().reject(new Error(privateMarker));
  await settle();
  check(view.fallbackCalls.length === 0, "No fallback clipboard write occurs after closure or version mismatch");
}

{
  const view = await ready({ clipboard: "missing" });
  view.document.onSelect = view.pagehide;
  await view.node("copy").click();
  check(view.fallbackCalls.length === 0, "Selection-triggered disposal cannot write to the clipboard");
}

{
  const view = fixture({ blocked: true, hero: false });
  view.node("open").click();
  check(view.node("open").disabled && view.calls.length === 0, "An initially blocked page never requests diagnostics");
  check(view.body.children[0] === view.node("entry"), "The diagnostic entry remains discoverable when no hero exists");
}

console.log(`PASS: ${checks} diagnostic UI checks`);

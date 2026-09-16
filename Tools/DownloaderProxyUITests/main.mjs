// Exercise the real incremental proxy UI without browser state or network access.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../DownloaderHelper/static/desktop.js", import.meta.url), "utf8");
const start = source.indexOf("  function installProxyControls() {");
const end = source.indexOf("  function scheduleDecoration() {", start);
assert(start >= 0 && end > start);
const implementation = source.slice(start, end);
let checks = 0;

function check(condition, message) {
  assert(condition, message);
  checks += 1;
}

class Element {
  constructor(tag) {
    this.tagName = tag;
    this.children = [];
    this.listeners = new Map();
    this.attributes = new Map();
    this.value = "";
    this.checked = false;
    this.disabled = false;
    this.hidden = false;
    this.classes = new Set();
    this.classList = {
      contains: (name) => this.classes.has(name),
      add: (name) => this.classes.add(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name)
    };
  }
  append(...nodes) {
    this.children.push(...nodes);
    nodes.forEach((node) => { if (typeof node !== "string") node.parentElement = this; });
  }
  after(node) {
    const siblings = this.parentElement.children;
    siblings.splice(siblings.indexOf(this) + 1, 0, node);
    node.parentElement = this.parentElement;
  }
  set textContent(value) { this.children = [String(value)]; }
  get textContent() { return this.children.map((node) => typeof node === "string" ? node : node.textContent).join(""); }
  setAttribute(name, value) { this.attributes.set(name, value); }
  addEventListener(name, handler) { this.listeners.set(name, handler); }
  fire(name) { this.listeners.get(name)?.({ preventDefault() {} }); }
  find(id) {
    if (this.id === id) return this;
    for (const node of this.children) {
      const match = typeof node !== "string" && node.find(id);
      if (match) return match;
    }
    return null;
  }
}

const direct = { enabled: false, configured: false, display_url: "", has_credentials: false };
const configured = { enabled: true, configured: true, display_url: "http://127.0.0.1:7897", has_credentials: false };
const settle = async () => { for (let index = 0; index < 12; index += 1) await Promise.resolve(); };

function fixture({ blocked = false } = {}) {
  const body = new Element("body");
  if (blocked) body.classes.add("version-blocked");
  const original = new Element("form");
  original.id = "settings-form";
  body.append(original);
  const calls = [];
  const observers = [];
  const timers = new Map();
  let timerID = 0;
  let confirmation = true;
  let confirmCount = 0;
  const context = vm.createContext({
    document: { body, querySelector: (selector) => body.find(selector.slice(1)), createElement: (tag) => new Element(tag) },
    window: { confirm() { confirmCount += 1; return confirmation; } },
    closed: false, URL, AbortController,
    setTimeout(callback) { timerID += 1; timers.set(timerID, callback); return timerID; },
    clearTimeout(id) { timers.delete(id); },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; observers.push(this); }
      observe() {}
      disconnect() { this.disconnected = true; }
    },
    fetch(path, options) {
      return new Promise((resolve, reject) => {
        options.signal.addEventListener("abort", () => reject(new Error("Aborted")), { once: true });
        calls.push({
          path, options, body: options.body ? JSON.parse(options.body) : null,
          resolve(data, status = 200) { resolve({ ok: status >= 200 && status < 300, status, json: async () => data }); },
          reject
        });
      });
    }
  });
  vm.runInContext(`${implementation}\nglobalThis.dispose = installProxyControls();`, context);
  return {
    body, original, calls, timers,
    node: (suffix) => body.find(`desktop-proxy-${suffix}`),
    setConfirm(value) { confirmation = value; },
    get confirmCount() { return confirmCount; },
    block() { body.classes.add("version-blocked"); observers.forEach((observer) => { if (!observer.disconnected) observer.callback(); }); },
    expire() { [...timers.values()].forEach((callback) => callback()); },
    close() { context.closed = true; context.dispose(); }
  };
}

async function loaded(state = direct) {
  const page = fixture();
  check(page.calls.length === 1 && page.calls[0].options.method === "GET", "Initialization performs only a read");
  check(page.node("save").disabled && page.node("test").disabled && page.node("clear").disabled,
    "All mutations are disabled before the initial read completes");
  page.calls[0].resolve(state);
  await settle();
  return page;
}

{
  const page = await loaded({ ...configured, display_url: "http://secret-user:secret-password@127.0.0.1:7897", has_credentials: true });
  check(page.node("form").parentElement === page.original.parentElement, "The proxy form is separate from original settings");
  check(page.node("url").type === "password" && page.node("url").autocomplete === "off", "Proxy credentials are masked and not autofilled");
  check(page.node("url").value === "" && !page.body.textContent.includes("secret-"), "Saved credentials never enter the rendered UI or input");
  check(page.node("saved").textContent.includes("127.0.0.1:7897") && page.node("saved").textContent.includes("认证"), "The safe endpoint and saved-credential state remain visible");
  page.node("enabled").checked = false;
  page.node("enabled").fire("change");
  page.node("form").fire("submit");
  check(JSON.stringify(page.calls[1].body) === '{"enabled":false}', "A blank address preserves stored credentials when disabling");
  check(page.node("url").disabled && page.node("test").disabled && page.node("clear").disabled, "Save locks all proxy controls");
  page.node("test").fire("click");
  page.node("form").fire("submit");
  check(page.calls.length === 2, "Repeated events cannot overlap a pending save");
  page.calls[1].resolve({ ...configured, enabled: false, has_credentials: true });
  await settle();
  check(!page.node("save").disabled && page.node("url").value === "", "A completed save unlocks controls without exposing credentials");
  check(page.timers.size === 0, "Successful requests dispose timeout timers");
  page.close();
}

for (const scheme of ["http", "https", "socks5"]) {
  const page = await loaded();
  page.node("url").value = `${scheme}://127.0.0.1:7897/`;
  page.node("url").fire("input");
  page.node("test").fire("click");
  check(page.calls[1].path === "/api/native/proxy/test" && page.calls[1].body.url.startsWith(`${scheme}://`), `${scheme} supports testing an unsaved endpoint`);
  check(page.calls[1].body.enabled === true && !page.node("enabled").checked, "Testing does not alter the enabled draft");
  page.calls[1].resolve({ ok: true, elapsed_ms: 123 });
  await settle();
  check(page.node("url").value.startsWith(`${scheme}://`) && page.node("status").textContent.includes("0.12"), "Testing preserves unsaved input and reports elapsed time");
  check(page.node("saved").textContent.includes("尚未"), "Testing does not claim to have saved settings");
  page.close();
}

{
  const page = await loaded();
  for (const invalid of ["ftp://127.0.0.1:7897", "http://127.0.0.1:7897/path", "http://127.0.0.1:7897/?secret=value", "socks5://name:password@127.0.0.1:7897"]) {
    page.node("url").value = invalid;
    page.node("test").fire("click");
    check(page.calls.length === 1, "Unsupported or unsafe addresses fail before network access");
    check(!page.node("status").textContent.includes("password") && !page.node("status").textContent.includes("secret=value"), "Validation never echoes sensitive input");
  }
  check(page.node("status").textContent.includes("本地 HTTP"), "SOCKS authentication errors recommend the supported local HTTP entry");
  page.node("url").value = "http://name:password@127.0.0.1:7897";
  page.node("enabled").checked = true;
  page.node("form").fire("submit");
  check(page.calls[1].body.url.includes("name:password@"), "HTTP authentication is sent only in the explicit save body");
  page.calls[1].resolve({ detail: { code: "proxy_busy", message: "raw password failure" } }, 409);
  await settle();
  check(page.node("url").value.includes("password") && !page.body.textContent.includes("raw password"), "Busy errors preserve drafts while suppressing raw server messages");
  check(!page.node("save").disabled && page.node("status").textContent.includes("后处理"), "Busy errors explain that active work must finish before saving");
  page.close();
}

{
  const page = fixture();
  page.calls[0].reject(new Error("Raw http://user:password@host"));
  await settle();
  check(page.node("save").disabled && page.node("test").disabled && page.node("clear").disabled, "An unknown initial connection failure never permits blind overwrites or deletion");
  check(!page.node("retry").hidden && !page.node("retry").disabled, "An initial read failure provides an enabled retry action");
  check(!page.body.textContent.includes("password"), "Network exception details are not displayed");
  page.node("retry").fire("click");
  page.calls[1].resolve(direct);
  await settle();
  check(!page.node("save").disabled && page.node("retry").hidden, "A successful re-read recovers normal controls");
  page.close();
}

{
  const page = fixture();
  page.calls[0].resolve({ detail: { code: "proxy_settings_unreadable" } }, 503);
  await settle();
  check(page.node("save").disabled && page.node("test").disabled && !page.node("clear").disabled, "Confirmed corrupt settings allow only explicit reset or re-read");
  page.setConfirm(false);
  page.node("clear").fire("click");
  check(page.calls.length === 1 && page.confirmCount === 1, "Cancelling corrupt-settings confirmation performs no write");
  page.setConfirm(true);
  page.node("clear").fire("click");
  check(JSON.stringify(page.calls[1].body) === '{"enabled":false,"url":""}', "Confirmed corruption reset explicitly clears and disables the proxy");
  page.calls[1].resolve(direct);
  await settle();
  check(!page.node("save").disabled && page.node("clear").disabled && page.node("retry").hidden, "A repaired configuration restores safe direct-mode controls");
  page.close();
}

{
  const page = await loaded(configured);
  page.node("url").value = "https://user:password@127.0.0.1:7897";
  page.node("url").fire("input");
  page.node("form").fire("submit");
  page.expire();
  await settle();
  check(page.calls[1].options.signal.aborted && !page.node("retry").disabled, "The request timeout aborts a stalled save and offers re-read");
  check(page.node("save").disabled && page.node("status").textContent.includes("30 秒"), "An ambiguous timed-out save requires reconciliation before another write");
  page.node("retry").fire("click");
  page.calls[2].resolve({ ...configured, enabled: false });
  await settle();
  check(page.node("url").value.includes("password") && page.node("enabled").checked, "Reconciliation preserves unsaved address and enabled edits");
  page.node("test").fire("click");
  page.expire();
  await settle();
  check(!page.node("test").disabled && !page.node("save").disabled, "A read-only test timeout does not permanently lock the form");
  page.close();
}

{
  const page = fixture({ blocked: true });
  check(page.calls.length === 0 && page.node("save").disabled && page.node("retry").disabled, "Version-blocked startup performs no proxy requests");
  page.node("form").fire("submit");
  page.node("retry").fire("click");
  page.node("test").fire("click");
  check(page.calls.length === 0, "Programmatic events cannot bypass the version gate");
  page.close();
}

{
  const page = await loaded(configured);
  page.node("test").fire("click");
  page.block();
  await settle();
  check(page.calls[1].options.signal.aborted && page.node("save").disabled && page.node("test").disabled,
    "A version mismatch aborts in-flight work and does not reopen controls");
  page.node("url").value = "sensitive draft";
  page.close();
  check(page.node("url").value === "" && page.node("clear").disabled, "Closing clears sensitive drafts and disables controls");
}

console.log(`PASS: ${checks} proxy UI checks`);

// Exercise the native profile controls with the preserved engine's real handlers.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const nativeSource = fs.readFileSync(new URL("../DownloaderHelper/static/chrome_profiles.js", import.meta.url), "utf8");
const engineSource = fs.readFileSync(new URL("../DownloaderHelper/vendor/rednote/app/static/app.js", import.meta.url), "utf8");
const marker = "  initialize();\n})();\n";
assert.equal(engineSource.split(marker).length, 2);
const instrumented = engineSource.replace(marker, `
  api = async (path, options = {}) => window.fakeAPI(path, options);
  showToast = () => {};
  setButtonLoading = () => {};
  fetchJobs = async () => {};
  window.engine = {loadConfig, saveConfig, createJob, state};
})();
`);
let checks = 0;
function check(condition, message) { assert(condition, message); checks += 1; }
const settle = async () => { for (let index = 0; index < 50; index += 1) await Promise.resolve(); };

class Element {
  constructor(tag, document) {
    this.tagName = tag;
    this.document = document;
    this.children = [];
    this.listeners = [];
    this.attributes = new Map();
    this.value = "";
    this.checked = true;
    this.hidden = false;
    this._disabled = false;
    const classes = new Set();
    this.classList = {
      contains: (name) => classes.has(name), add: (name) => classes.add(name),
      toggle: (name, on) => on ? classes.add(name) : classes.delete(name)
    };
  }
  set disabled(value) {
    if (this._disabled === value) return;
    this._disabled = value;
    this.document.observers.forEach((observer) => {
      if (observer.target === this && !observer.disconnected) queueMicrotask(() => observer.callback());
    });
  }
  get disabled() { return this._disabled; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text || this.children.map((child) => child.textContent).join(""); }
  set innerHTML(_) { throw new Error("Profile controls must use textContent"); }
  append(...nodes) { this.children.push(...nodes); nodes.forEach((child) => { child.parentElement = this; }); }
  replaceChildren(...nodes) { this._text = ""; this.children = []; this.append(...nodes); }
  after(node) {
    this.parentElement.children.splice(this.parentElement.children.indexOf(this) + 1, 0, node);
    node.parentElement = this.parentElement;
  }
  setAttribute(name, value) { this.attributes.set(name, value); }
  addEventListener(type, handler, capture = false) { this.listeners.push({type, handler, capture}); }
  dispatchEvent(event) {
    event.preventDefault ||= function () { this.defaultPrevented = true; };
    event.stopImmediatePropagation ||= function () { this.stopped = true; };
    for (const capture of [true, false]) {
      for (const listener of this.listeners.filter((item) => item.type === event.type && item.capture === capture)) {
        if (event.stopped) return false;
        listener.handler(event);
      }
    }
    return !event.defaultPrevented;
  }
  fire(type) { return this.dispatchEvent({type}); }
  focus() { this.document.focused = this; }
  find(id) {
    if (this.id === id) return this;
    for (const child of this.children) { const found = child.find(id); if (found) return found; }
    return null;
  }
}

const available = {
  schema_version: 1, status: "ok", selected_profile: "Profile 1", selected_status: "available",
  use_chrome_cookies: true,
  profiles: [{directory: "Profile 1", has_cookie_database: true}, {directory: "Profile 4", has_cookie_database: false}]
};
const missing = {...available, selected_profile: "Default", selected_status: "missing"};

async function fixture(state = missing) {
  const document = {observers: []};
  document.body = new Element("body", document);
  document.createElement = (tag) => new Element(tag, document);
  const ids = [...engineSource.matchAll(/document\.querySelector\("#([^"]+)"\)/g)].map((match) => match[1]);
  for (const id of new Set(ids)) { const element = document.createElement("input"); element.id = id; document.body.append(element); }
  const cookieLabel = document.createElement("label");
  cookieLabel.id = "fixture-cookie-label";
  cookieLabel.htmlFor = "chrome-cookies";
  document.body.append(cookieLabel);
  document.querySelector = (selector) => {
    if (selector.startsWith("#")) return document.body.find(selector.slice(1));
    const labelFor = selector.match(/^label\[for="([^"]+)"\]$/)?.[1];
    return labelFor === cookieLabel.htmlFor ? cookieLabel : null;
  };
  const node = (id) => document.querySelector(`#${id}`);
  node("download-dir").value = "/fixture";
  node("url-input").value = "https://www.douyin.com/video/123";
  const calls = [];
  const nativeCalls = [];
  const timers = new Map();
  const windowEvents = new Map();
  let timerID = 0;
  let config = {chrome_profile: state.selected_profile, use_chrome_cookies: state.use_chrome_cookies, download_dir: "/fixture"};
  let delay = null;
  let failSave = false;
  const window = {
    addEventListener(name, callback) { windowEvents.set(name, callback); },
    setTimeout() {},
    async fakeAPI(path, options) {
      calls.push({path, options});
      if (options.method === "PUT") {
        if (delay) await delay;
        if (failSave) throw new Error("Synthetic save failure");
        config = JSON.parse(options.body);
      }
      return path === "/api/config" ? {...config} : {};
    }
  };
  const context = vm.createContext({
    document, window, console, URL, AbortController, TextDecoder,
    Event: class { constructor(type) { this.type = type; } },
    setTimeout(callback) { timers.set(++timerID, callback); return timerID; },
    clearTimeout(id) { timers.delete(id); },
    MutationObserver: class {
      constructor(callback) { this.callback = callback; document.observers.push(this); }
      observe(target) { this.target = target; }
      disconnect() { this.disconnected = true; }
    },
    fetch(path, options) {
      return new Promise((resolve, reject) => {
        options.signal.addEventListener("abort", () => reject(new Error("Synthetic timeout")), {once: true});
        nativeCalls.push({path, options, reject, resolve(data, status = 200) {
          resolve(new Response(JSON.stringify(data), {status, headers: {"content-type": "application/json"}}));
        }});
      });
    }
  });
  vm.runInContext(instrumented, context);
  await window.engine.loadConfig();
  node("settings-form").addEventListener("submit", window.engine.saveConfig);
  node("download-form").addEventListener("submit", window.engine.createJob);
  vm.runInContext(nativeSource, context);
  return {
    document, node, calls, nativeCalls, window,
    native: (suffix) => node(`desktop-chrome-profile${suffix ? `-${suffix}` : ""}`),
    resolve(data = state) { nativeCalls.at(-1).resolve(data); },
    pauseSave() { let release; delay = new Promise((resolve) => {release = resolve;}); return release; },
    failSave() { failSave = true; },
    choose(value) { node("desktop-chrome-profile").value = value; node("desktop-chrome-profile").fire("change"); },
    block() { document.body.classList.add("version-blocked"); document.observers.filter((o) => o.target === document.body).forEach((o) => o.callback()); },
    expire() { [...timers.values()].forEach((callback) => callback()); },
    close() { windowEvents.get("pagehide")(); },
    get config() { return config; }
  };
}

{
  const page = await fixture();
  check(page.nativeCalls.length === 1 && page.nativeCalls[0].options.method === "GET", "Initialization only reads native profile metadata");
  check(page.node("fixture-cookie-label").htmlFor === "desktop-chrome-cookies", "The existing label targets the visible native switch, not its hidden bridge");
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Capture handler blocks creation while initial inventory is pending");
  page.node("desktop-chrome-cookies").checked = false;
  page.node("settings-form").fire("submit");
  check(!page.calls.some((call) => call.options.method === "PUT"), "Pending initial configuration cannot be overwritten by an early cookie-off save");
  page.node("desktop-chrome-cookies").checked = true;
  page.resolve(); await settle();
  check(page.native().value === "Default" && page.node("chrome-profile").value === "Default", "Missing saved Default is preserved, never silently replaced");
  check(page.native().children.some((option) => option.value === "Default" && option.disabled), "Missing saved profile remains visibly marked");
  check(!page.native().children.some((option) => option.value === "Profile 2"), "Choices contain actual inventory, not hardcoded examples");
  page.node("download-form").fire("submit");
  check(page.calls.length === 1, "Missing enabled profile blocks creating before original handler");
  page.choose("Profile 1");
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Choosing an available profile does not skip explicit save");
  const release = page.pauseSave();
  page.node("settings-form").fire("submit");
  check(page.calls.filter((call) => call.options.method === "PUT").length === 1 && page.native().disabled, "Real original save handler owns the only settings write");
  page.node("download-form").fire("submit");
  page.node("settings-form").fire("submit");
  check(page.calls.filter((call) => call.options.method === "PUT").length === 1, "Pending save cannot be duplicated");
  release(); await settle();
  check(page.nativeCalls.length === 2 && page.native().disabled, "Save completion rechecks persisted selection before allowing jobs");
  page.resolve(available); await settle();
  page.node("download-form").fire("submit"); await settle();
  check(page.config.chrome_profile === "Profile 1" && page.calls.filter((call) => call.path === "/api/jobs").length === 1, "A verified saved profile permits exactly one new task");
  check(page.calls.every((call) => !call.path.includes("retry")), "No old task is rebound or retried");
  page.close();
}

{
  const page = await fixture(); page.resolve(); await settle();
  page.node("download-dir").value = "/fixture/new-directory";
  page.node("settings-form").fire("submit"); await settle();
  page.resolve(); await settle();
  check(page.config.chrome_profile === "Default" && page.config.download_dir === "/fixture/new-directory", "Unrelated settings edits preserve an unchanged missing explicit profile");
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Preserving legacy settings does not bypass strict new-task preflight");
  page.close();
}

{
  const page = await fixture(); page.resolve(); await settle();
  page.choose("Profile 1");
  page.node("desktop-chrome-cookies").checked = false;
  page.node("desktop-chrome-cookies").fire("change");
  await page.window.engine.loadConfig();
  check(page.node("chrome-profile").value === "Default" && page.node("chrome-cookies").checked, "Late original load actually overwrites its own hidden controls");
  check(page.native().value === "Profile 1" && !page.node("desktop-chrome-cookies").checked, "Late original load cannot replace visible profile and cookie drafts");
  page.node("settings-form").fire("submit"); await settle();
  page.resolve({...available, use_chrome_cookies: false}); await settle();
  check(page.config.chrome_profile === "Profile 1" && page.config.use_chrome_cookies === false, "Save synchronizes intended visible drafts before original handler reads them");
  page.close();
}

{
  const page = await fixture(); page.resolve(); await settle();
  page.choose("Profile 1"); page.failSave();
  page.node("settings-form").fire("submit"); await settle();
  page.resolve(); await settle();
  check(page.native().value === "Profile 1" && page.config.chrome_profile === "Default", "Failed save retains draft and original persisted configuration");
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Failed save cannot authorize a task under different identity");
  page.native("refresh").fire("click"); page.resolve(); await settle();
  check(page.native().value === "Profile 1", "Refresh preserves an unsaved deliberate selection");
  page.close();
}

{
  const page = await fixture(); page.resolve(); await settle();
  page.node("desktop-chrome-cookies").checked = false; page.node("desktop-chrome-cookies").fire("change");
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Unsaved cookie-off cannot bypass saved enabled-cookie policy");
  page.node("settings-form").fire("submit"); await settle();
  page.resolve({...missing, use_chrome_cookies: false}); await settle();
  page.node("download-form").fire("submit"); await settle();
  check(page.config.chrome_profile === "Default" && page.config.use_chrome_cookies === false, "Explicit cookie-off preserves missing selected identity");
  check(page.calls.some((call) => call.path === "/api/jobs"), "Saved cookie-off allows new task without profile availability");
  page.close();
}

for (const [state, allowed] of [
  [{...available, selected_profile: null, selected_status: "automatic"}, true],
  [{...available, selected_profile: null, selected_status: "automatic", profiles: []}, true],
  [{...available, selected_profile: null, selected_status: "automatic", status: "cookie_permission_denied", profiles: []}, true],
  [{...available, selected_profile: "Profile 4", selected_status: "cookie_database_missing"}, false],
  [{...available, status: "cookie_permission_denied", selected_status: "unverified", profiles: []}, false],
  [{...missing, status: "chrome_data_directory_missing", selected_status: "unverified", profiles: [], use_chrome_cookies: false}, true],
  [{...missing, selected_profile: null, selected_status: "invalid"}, false]
]) {
  const page = await fixture(state); page.resolve(); await settle();
  page.node("download-form").fire("submit"); await settle();
  check(page.calls.some((call) => call.path === "/api/jobs") === allowed, `Creation gate follows explicit cookie policy and scan status ${state.selected_status}/${state.status}`);
  if (state.selected_status === "automatic") check(page.config.chrome_profile === null && page.native().value === "", "Automatic mode is preserved without selecting another account");
  if (state.selected_status === "unverified") check(!page.native().textContent.includes("已不存在"), "Unverified scans do not misdiagnose a deleted profile");
  page.close();
}

for (const malformed of [
  {...available, profiles: [{directory: "/private/DO_NOT_DISCLOSE", has_cookie_database: true}]},
  {...available, profiles: [...available.profiles, available.profiles[0]]},
  {...available, selected_profile: "DO_NOT_DISCLOSE"},
  {...available, selected_status: "automatic"},
  {...available, extra: "x".repeat(70 * 1024)}
]) {
  const page = await fixture(available); page.resolve(malformed); await settle();
  page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs") && page.native().disabled, "Malformed inventory fails closed before original creation handler");
  check(!page.document.body.textContent.includes("DO_NOT_DISCLOSE"), "Untrusted profile paths and values are never rendered");
  page.close();
}

{
  const page = await fixture(available); page.expire(); await settle();
  check(page.native("status").textContent.includes("刷新") && !page.native("refresh").disabled, "Timed-out scan offers retry without clearing selected settings");
  page.native("refresh").fire("click"); page.resolve(); await settle();
  check(page.native().value === "Profile 1", "Refresh recovers after a scan timeout");
  page.block(); page.node("download-form").fire("submit");
  check(!page.calls.some((call) => call.path === "/api/jobs"), "Version mismatch blocks native and original creation handlers");
  page.close();
}

{
  const page = await fixture(); page.close(); page.resolve(available); await settle();
  check(page.native().disabled && page.config.chrome_profile === "Default", "Closing discards stale inventory without changing settings");
}

console.log(`PASS: ${checks} native Chrome profile UI checks`);

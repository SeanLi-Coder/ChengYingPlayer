// Exercise the production output index with synthetic jobs and no browser or network.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { performance } from "node:perf_hooks";

const source = fs.readFileSync(new URL("../DownloaderHelper/static/desktop.js", import.meta.url), "utf8");
const start = source.indexOf("  function createOutputIndex(outputs) {");
const end = source.indexOf("  const observer = new MutationObserver(scheduleDecoration);", start);
assert(start >= 0 && end > start);
const implementation = source.slice(start, end);
let checks = 0;

function check(condition, message) {
  assert(condition, message);
  checks += 1;
}

function snapshot(outputs) {
  return JSON.stringify([...outputs].sort(([left], [right]) => left.localeCompare(right)));
}

// Frozen pre-change acceptJob algorithm: retain Map order and rebuild every path.
function legacyIndex() {
  const jobs = new Map();
  const outputs = new Map();
  return {
    outputs,
    accept(job) {
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
    }
  };
}

function fixture({ observeMaps = true } = {}) {
  const metrics = { decorations: 0, mapValueVisits: 0 };
  const maps = [];
  class ObservedMap extends Map {
    constructor(...args) { super(...args); maps.push(this); }
    *values() {
      for (const value of super.values()) {
        metrics.mapValueVisits += 1;
        yield value;
      }
    }
  }
  const requests = [];
  const context = vm.createContext({
    Map: observeMaps ? ObservedMap : Map,
    scheduleDecoration() { metrics.decorations += 1; },
    fetch(path, options) {
      return new Promise((resolve) => requests.push({
        path, options,
        resolve(data, ok = true) { resolve({ ok, json: async () => data }); }
      }));
    },
    closed: false
  });
  vm.runInContext(`${implementation}\nconst outputs = new Map();\nconst outputIndex = createOutputIndex(outputs);\nglobalThis.fixture = { outputs, outputIndex, acceptJob, acceptJobs, refreshOutputs };`, context);
  return { ...context.fixture, context, metrics, requests, maps };
}

function item(id, paths, status = "completed") {
  return { id, status, output_paths: paths };
}

function job(id, revision, items) {
  return { id, revision, items };
}

function matchesOracle(page, oracle, message) {
  check(snapshot(page.outputs) === snapshot(oracle.outputs), message);
}

{
  const page = fixture();
  const oracle = legacyIndex();
  const changes = [
    job("first", 1, [item("one", ["/synthetic/shared.mp4", "/synthetic/first.webp", 42]), item("last", ["/synthetic/shared.mp4", "/synthetic/shared.mp4"])]),
    job("second", 1, [item("two", ["/synthetic/shared.mp4"])]),
    job("first", 2, [item("changed", ["/synthetic/shared.mp4"])]),
    job("second", 2, [item("two", ["/synthetic/shared.mp4"], "queued")]),
    job("second", 3, [item("retry", ["/synthetic/shared.mp4", "/synthetic/new.mp4"])]),
    job("first", 3, []),
    job("first", 4, [item("reintroduced", ["/synthetic/shared.mp4"])]),
    job("second", 4, []),
    job("first", 5, [item("failed", ["/synthetic/shared.mp4"], "failed")])
  ];
  for (const [index, update] of changes.entries()) {
    page.acceptJob(update);
    oracle.accept(update);
    matchesOracle(page, oracle, `Collision, retry, and removal step ${index} matches the original winner`);
    if (index === 0) check(page.outputs.get("/synthetic/shared.mp4").index === 1, "The last path occurrence within the last matching item wins");
  }
  check(page.outputs.size === 0, "Removing the last completed owner removes its output permission");
  const retainedJobs = page.maps[1];
  const retainedOwners = page.maps[2];
  check(retainedOwners.size === 0, "Removed paths do not retain owner caches");
  check([...retainedJobs].every(([, value]) => Object.keys(value).sort().join() === "order,paths,revision" && value.paths.size === 0), "The cache keeps no duplicate job or item payloads");
}

{
  const page = fixture();
  let visits = 0;
  const items = [item("one", ["/synthetic/one.mp4"])];
  items[Symbol.iterator] = function* () { visits += 1; yield this[0]; };
  page.acceptJob(job("one", 2, items));
  page.acceptJob(job("one", 2, items));
  page.acceptJob(job("one", 1, items));
  check(visits === 1 && page.metrics.decorations === 1, "Equal and stale finite revisions do not scan items or schedule decoration");
  page.acceptJob(job("one", 3, [item("one", ["/synthetic/one.mp4"], "downloading")]));
  check(!page.outputs.has("/synthetic/one.mp4"), "A higher revision retry immediately removes obsolete completed-file mappings");
  for (const revision of [undefined, null, NaN, Infinity, "4"]) {
    page.acceptJob(job("legacy", revision, [item("legacy", ["/synthetic/legacy.mp4"])]));
    page.acceptJob(job("legacy", revision, []));
    check(!page.outputs.has("/synthetic/legacy.mp4"), "Legacy or nonnumeric revisions are not mistaken for unchanged snapshots");
  }
  for (const invalid of [null, {}, { id: 4, items: [] }, { id: "bad", items: null }]) {
    check(page.outputIndex.accept(invalid) === false, "Malformed top-level jobs cannot change the index");
  }
}

{
  const page = fixture();
  const oracle = legacyIndex();
  let seed = 1234567;
  const random = (maximum) => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed % maximum;
  };
  const revisions = new Map();
  const snapshots = [];
  for (let index = 0; index < 1500; index += 1) {
    let update;
    if (snapshots.length && random(5) === 0) update = snapshots[random(snapshots.length)];
    else {
      const id = `random-${random(40)}`;
      const revision = (revisions.get(id) || 0) + 1;
      revisions.set(id, revision);
      update = job(id, revision, Array.from({ length: random(7) }, (_, itemIndex) =>
        item(`item-${itemIndex}`, Array.from({ length: random(4) }, () => `/synthetic/${random(35)}.mp4`), random(4) ? "completed" : "queued")));
      snapshots.push(update);
    }
    page.acceptJob(update);
    oracle.accept(update);
    matchesOracle(page, oracle, `Random ordered/stale/repeated update ${index} matches the original index`);
  }
}

{
  const page = fixture();
  const oracle = legacyIndex();
  const refresh = page.refreshOutputs();
  check(page.requests[0].path === "/api/jobs", "History refresh remains a read-only request to the original API");
  const live = job("live", 4, [item("new", ["/synthetic/shared.mp4"])]);
  page.acceptJob(live);
  oracle.accept(live);
  const history = [job("history", 1, [item("old", ["/synthetic/shared.mp4"])]), job("live", 2, [])];
  page.requests[0].resolve(history);
  await refresh;
  history.forEach(oracle.accept);
  matchesOracle(page, oracle, "An initial response arriving after SSE cannot roll back the newer job or change first-seen collision order");
  check(page.metrics.decorations === 2, "A history batch schedules decoration once after its accepted jobs");
  const repeat = page.refreshOutputs();
  page.requests[1].resolve([history[0], live]);
  await repeat;
  check(page.metrics.decorations === 2, "A duplicate reconnect snapshot schedules no extra decoration");
  const close = page.refreshOutputs();
  page.context.closed = true;
  page.requests[2].resolve([job("closed", 1, [item("bad", ["/synthetic/closed.mp4"])])]);
  await close;
  check(!page.outputs.has("/synthetic/closed.mp4"), "A response after page closure cannot add output permissions");
}

{
  const page = fixture();
  const shared = "/synthetic/shared.mp4";
  const count = 1000;
  page.acceptJobs(Array.from({ length: count }, (_, index) => job(`owner-${index}`, 1, [item("one", [shared])])));
  check(page.outputs.get(shared).jobID === "owner-999", "A thousand colliding owners retain original first-seen precedence");
  check(page.metrics.decorations === 1 && page.metrics.mapValueVisits === 0, "Collision initialization uses cached winners without scanning previous owners");
  for (let index = 0; index < count; index += 1) page.acceptJob(job(`owner-${index}`, 2, [item("updated", [shared])]));
  check(page.metrics.mapValueVisits === 0, "Updating a thousand existing owners never rescans the collision bucket");
  page.acceptJob(job("owner-0", 3, []));
  check(page.metrics.mapValueVisits === 0, "Removing a nonwinning owner does not scan the bucket");
  page.acceptJob(job("owner-999", 3, []));
  check(page.outputs.get(shared).jobID === "owner-998" && page.metrics.mapValueVisits === 998, "Removing the winner scans only its remaining colliding owners and restores the next winner");
}

{
  const page = fixture();
  const messages = [];
  let blocked = false;
  class Element {
    constructor() { this.children = []; this.listeners = new Map(); }
    append(value) { this.children.push(value); }
    setAttribute() {}
    addEventListener(name, handler) { this.listeners.set(name, handler); }
    querySelector(selector) { return this.children.find((child) => selector === `.${child.className}`) || null; }
  }
  const entry = new Element();
  entry.title = "/synthetic/click.mp4";
  entry.textContent = "Synthetic video";
  Object.assign(page.context, {
    bridge: { postMessage: (message) => messages.push(JSON.parse(JSON.stringify(message))) },
    document: {
      body: { classList: { contains: () => blocked } },
      querySelectorAll: (selector) => selector === ".item-files li[title]" ? [entry] : [],
      createElement: () => new Element()
    },
    restoredFileLists: new WeakSet(), expandedFiles: new Set()
  });
  const sendStart = source.indexOf("  function send(message) {");
  const sendEnd = source.indexOf("  window.chengyingDownloadCenter", sendStart);
  const decorateStart = source.indexOf("  function decorateFiles() {");
  const decorateEnd = source.indexOf("  function rememberFileDisclosure(event)", decorateStart);
  vm.runInContext(source.slice(sendStart, sendEnd) + source.slice(decorateStart, decorateEnd), page.context);
  page.acceptJob(job("older", 1, [item("old", [entry.title])]));
  page.context.decorateFiles();
  const click = () => entry.children[0].children[0].listeners.get("click")({ preventDefault() {}, stopPropagation() {} });
  page.acceptJob(job("newer", 1, [item("new", [entry.title])]));
  click();
  check(messages.at(-1).jobID === "newer" && messages.at(-1).itemID === "new", "A previously rendered button resolves the current winning record at click time");
  page.acceptJob(job("newer", 2, []));
  click();
  check(messages.at(-1).jobID === "older", "A retained button uses the remaining owner after a retry removes the previous winner");
  page.acceptJob(job("older", 2, []));
  const before = messages.length;
  click();
  check(messages.length === before, "A retained button cannot send a removed path record");
  page.acceptJob(job("older", 3, [item("restored", [entry.title])]));
  blocked = true;
  click();
  check(messages.length === before, "The existing version-block gate still blocks native file actions");
}

function measuredJobs(metrics) {
  return Array.from({ length: 1000 }, (_, index) => {
    const items = Array.from({ length: 20 }, (_, number) => item(`item-${number}`, [`/synthetic/${index}/${number}.mp4`]));
    items[Symbol.iterator] = function* () {
      for (let number = 0; number < this.length; number += 1) {
        metrics.itemVisits += 1;
        yield this[number];
      }
    };
    return job(`job-${index}`, 1, items);
  });
}

if (process.argv.includes("--benchmark")) {
  const timings = {};
  const final = [];
  const finalOutputs = [];
  for (const kind of ["legacy", "incremental"]) {
    const metrics = { itemVisits: 0 };
    const jobs = measuredJobs(metrics);
    const page = kind === "legacy" ? legacyIndex() : fixture({ observeMaps: false });
    const index = page.outputIndex || page;
    const initial = performance.now();
    jobs.forEach((value) => index.accept(value));
    const initialMs = performance.now() - initial;
    const initialVisits = metrics.itemVisits;
    metrics.itemVisits = 0;
    const updates = performance.now();
    for (let revision = 2; revision <= 101; revision += 1) index.accept({ ...jobs[500], revision });
    timings[kind] = { initialMs: +initialMs.toFixed(2), initialItemVisits: initialVisits,
      updateMs: +(performance.now() - updates).toFixed(2), updateItemVisits: metrics.itemVisits };
    final.push(timings[kind]);
    finalOutputs.push(snapshot(page.outputs));
  }
  check(final[0].initialItemVisits === 10010000 && final[1].initialItemVisits === 20000,
    "A thousand-job load changes cumulative history traversal to one visit per incoming item");
  check(final[0].updateItemVisits === 2000000 && final[1].updateItemVisits === 2000,
    "Single-job progress touches only that job's items across a thousand-job history");
  check(finalOutputs[0] === finalOutputs[1], "The benchmark's final output permissions exactly match the pre-change oracle");
  console.log(JSON.stringify({ benchmark: "1000 jobs x 20 outputs; 100 updates to one job", ...timings }));
}

console.log(`PASS: ${checks} synthetic output-index checks`);

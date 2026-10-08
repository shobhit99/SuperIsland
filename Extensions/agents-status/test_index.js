"use strict";
// Behavioural tests for index.js, run with `node --test Extensions/agents-status/`.
// index.js is loaded into a vm context with a scripted SuperIsland host:
// fetch responses are scripted per URL, timers are fired manually so the
// tests can model the host suspending repeating timers (lowPower mode).

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(path.join(__dirname, "index.js"), "utf8");

function loadExtension(respond) {
  const calls = [];
  const notifications = [];
  const oneShot = [];
  const repeating = [];
  let nextTimerID = 1;

  const View = new Proxy({}, {
    get: (_t, name) => (...args) => ({ view: name, args })
  });

  const sandbox = {
    console: { log() {} },
    setTimeout(fn, ms) { const id = nextTimerID++; oneShot.push({ id, fn, ms }); return id; },
    clearTimeout(id) { const i = oneShot.findIndex(t => t.id === id); if (i >= 0) oneShot.splice(i, 1); },
    setInterval(fn, ms) { const id = nextTimerID++; repeating.push({ id, fn, ms }); return id; },
    clearInterval(id) { const i = repeating.findIndex(t => t.id === id); if (i >= 0) repeating.splice(i, 1); },
    View,
    SuperIsland: {
      http: {
        fetch(url, options) {
          const method = (options && options.method) || "GET";
          calls.push({ url, method });
          return Promise.resolve(respond(url.replace(/^http:\/\/127\.0\.0\.1:7823/, ""), method));
        }
      },
      registerModule(m) { sandbox.__module = m; },
      settings: { get() { return undefined; } },
      notifications: { send(n) { notifications.push(n); } },
      island: { activate() {}, dismiss() {} },
      playFeedback() {}
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCE, sandbox, { filename: "index.js" });

  const flush = async () => { for (let i = 0; i < 20; i++) await new Promise(r => setImmediate(r)); };
  // Fire the earliest pending one-shot timer (as the host would in any energy mode).
  const fireOneShot = async () => {
    if (oneShot.length === 0) return false;
    oneShot.sort((a, b) => a.ms - b.ms);
    const t = oneShot.shift();
    t.fn();
    await flush();
    return true;
  };
  // Fire every repeating timer once (the host skips these while suspended).
  const fireRepeating = async () => { for (const t of [...repeating]) t.fn(); await flush(); };

  const texts = (node, out = []) => {
    if (!node || typeof node !== "object") return out;
    if (node.view === "text" && typeof node.args[0] === "string") out.push(node.args[0]);
    for (const a of (node.args || [])) Array.isArray(a) ? a.forEach(x => texts(x, out)) : texts(a, out);
    return out;
  };
  const headline = () => texts(sandbox.__module.fullExpanded());

  return { module: sandbox.__module, calls, notifications, oneShot, repeating, flush, fireOneShot, fireRepeating, headline };
}

const REFUSED = { status: 0, data: null, text: "", error: "Could not connect to the server." };
const ok = (data) => ({ status: 200, data, text: JSON.stringify(data) });

function bridge(opts) {
  // opts.resumeFailures: how many /control/resume calls fail before the bridge "comes up"
  // opts.down(): dynamic — when true every request is refused
  let resumeFailures = opts.resumeFailures || 0;
  return (path, _method) => {
    if (opts.down && opts.down()) return REFUSED;
    if (path === "/control/resume") {
      if (resumeFailures > 0) { resumeFailures--; return REFUSED; }
      return ok({ ok: true, paused: false });
    }
    if (path.startsWith("/state")) return ok({ sessions: [], state: "Idle" });
    if (path.startsWith("/hooks/install")) return ok({ ok: true });
    if (path === "/control/pause") return ok({ ok: true, paused: true });
    return { status: 404, data: { error: "not found" }, text: "" };
  };
}

test("should come online without a setup warning when the bridge starts listening a few seconds after activation", async () => {
  const ext = loadExtension(bridge({ resumeFailures: 3 }));
  ext.module.onActivate();
  await ext.flush();
  while (await ext.fireOneShot()) { /* activation retries */ }
  await ext.fireRepeating();

  assert.deepEqual(ext.notifications, []);
  assert.ok(ext.headline().includes("No active sessions"), "expected online hero, got " + ext.headline());
  assert.ok(ext.calls.some(c => c.url.includes("/hooks/install?agent=claude")), "hooks must be installed once the bridge is reachable");
});

test("should report setup failure once, only after the activation retries are exhausted", async () => {
  const ext = loadExtension(bridge({ down: () => true })); // bridge never comes up
  ext.module.onActivate();
  await ext.flush();
  const beforeRetries = ext.notifications.length;
  let attempts = ext.calls.filter(c => c.url.endsWith("/control/resume")).length;
  for (let i = 0; i < 100 && await ext.fireOneShot(); i++) { /* exhaust the retry chain */ }
  attempts = ext.calls.filter(c => c.url.endsWith("/control/resume")).length;

  assert.equal(beforeRetries, 0, "no warning while retries are still pending");
  assert.ok(attempts >= 5, "expected several resume attempts, got " + attempts);
  assert.equal(ext.notifications.length, 1);
  assert.equal(ext.notifications[0].title, "Agents Status: bridge unreachable");
  assert.ok(ext.headline().includes("Setup required"));
});

test("should recover from offline through one-shot probes while repeating timers are suspended", async () => {
  let down = false;
  const ext = loadExtension(bridge({ down: () => down }));
  ext.module.onActivate();
  await ext.flush();
  await ext.fireRepeating();
  assert.ok(ext.headline().includes("No active sessions"), "precondition: online after activation");

  down = true;
  await ext.fireRepeating();
  assert.ok(ext.headline().includes("Offline"), "precondition: poll failure marks the bridge offline");

  down = false;
  // Host in lowPower mode with the module hidden: repeating timers never fire.
  for (let i = 0; i < 10 && await ext.fireOneShot(); i++) { /* offline probes */ }

  assert.ok(ext.headline().includes("No active sessions"), "expected recovery via one-shot probe, got " + ext.headline());
});

test("should abandon pending activation retries after onDeactivate", async () => {
  const ext = loadExtension(bridge({ down: () => true }));
  ext.module.onActivate();
  await ext.flush();
  await ext.fireOneShot();
  ext.module.onDeactivate();
  const callsAtDeactivate = ext.calls.length;
  for (let i = 0; i < 100 && await ext.fireOneShot(); i++) { /* stale retry timers */ }

  assert.deepEqual(ext.notifications, [], "stale retries must not raise the setup warning");
  assert.equal(ext.repeating.length, 0, "polling must not start after deactivation");
  const laterCalls = ext.calls.slice(callsAtDeactivate).filter(c => !c.url.endsWith("/control/pause"));
  assert.deepEqual(laterCalls, [], "no bridge traffic after deactivation");
});

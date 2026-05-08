// Adapter shaping tests. Loads assets/adapter.js into a vm sandbox
// with minimal `window` stubs (ProuterdWS.call mocked, ProuterdCore
// for downloadUrl), then exercises public ProuterdAdapter methods
// against canned RPC reply payloads.
//
// No browser, no jsdom — just node:test + node:vm. Catches shape
// regressions (renamed fields, swapped types, dropped keys) cheaply.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

function loadAdapter(replies) {
  const calls = [];
  const window = {
    ProuterdWS: {
      call: (method, args) => {
        calls.push({ method, args });
        const r = replies[method];
        if (typeof r === "function") return Promise.resolve(r(args));
        if (r === undefined) return Promise.reject(Object.assign(new Error("no stub for " + method), { code: "internal" }));
        return Promise.resolve(r);
      }
    },
    ProuterdCore: {
      config: () => ({ url: "http://x:1" }),
      downloadUrl: (path) => "http://x:1" + path
    },
    ProuterdDiff: {
      lines: (l, r) => [{ action: "=", text: "stub", left_no: 1, right_no: 1 }]
    }
  };

  const ctx = vm.createContext({ window, Date, Object, Array, JSON, URLSearchParams, Math, Number, String, Boolean, Error, Promise, console });
  const src = readFileSync(join(ROOT, "assets", "adapter.js"), "utf8");
  vm.runInContext(src, ctx);
  return { adapter: window.ProuterdAdapter, calls };
}

test("runToHash maps wire fields to view-model: cost_usd, tokens, thread_id, created_at", async () => {
  const { adapter } = loadAdapter({
    "runs.list": {
      data: [{
        uid: "run_1", process_name: "p", status: "success",
        duration_ms: 1234, started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:00:01Z", created_at: "2026-01-01T00:00:00Z",
        commit_id: 42, interface_name: "cli", replay_of_uid: null,
        thread_id: "tid-9", tokens_in: 100, tokens_out: 50, cost_usd: 0.0042
      }]
    }
  });
  const [r] = await adapter.listRuns();
  assert.equal(r.run_uid, "run_1");
  assert.equal(r.process_name, "p");
  assert.equal(r.status, "success");
  assert.equal(r.duration_ms, 1234);
  assert.equal(r.config_commit, 42);
  assert.equal(r.trigger, "cli");
  assert.equal(r.thread_id, "tid-9");
  assert.equal(r.tokens_in, 100);
  assert.equal(r.tokens_out, 50);
  assert.equal(r.cost_usd, 0.0042);
  assert.equal(r.created_at, "2026-01-01T00:00:00Z");
});

test("runToHash defaults numeric fields to 0 when wire omits them", async () => {
  const { adapter } = loadAdapter({
    "runs.list": { data: [{ uid: "r", process_name: "p", status: "queued" }] }
  });
  const [r] = await adapter.listRuns();
  assert.equal(r.tokens_in, 0);
  assert.equal(r.tokens_out, 0);
  assert.equal(r.cost_usd, 0);
  assert.equal(r.thread_id, null);
});

test("blockToHash carries Phase-37 directives: skip_when, vars, fan_out, agentic, pause, barrier", async () => {
  const { adapter } = loadAdapter({
    "processes.get": {
      data: {
        name: "p", description: null, queue: "default", shutdown: false,
        thread_id_template: null,
        blocks: [
          {
            name: "b1", interface: { type: "docker", name: "img" }, call_fields: {},
            timeout_ms: null, retry_policy: null, contract: null, secret_names: [],
            shutdown: false,
            skip_when: { path: "x.y", operator: "eq", values: ["z"] },
            vars: { foo: "{{event.foo}}" },
            fan_out: { from: "items", into: "item", maps: [], dedupe: null, rate_limit: null },
            agentic: { allowed_tools: ["t1", "t2"], tool_call_limit: 5 },
            pause_reason: "wait for human",
            barrier: { for: "g", join_strategy: "all" },
            max_cost_usd: 1.5
          }
        ],
        routes: [], parallel_groups: []
      }
    }
  });
  const p = await adapter.getProcess("p");
  const b = p.blocks[0];
  assert.deepEqual(b.skip_when, { path: "x.y", operator: "eq", values: ["z"] });
  assert.deepEqual(b.vars, { foo: "{{event.foo}}" });
  assert.equal(b.fan_out.into, "item");
  assert.equal(b.agentic.tool_call_limit, 5);
  assert.equal(b.pause_reason, "wait for human");
  assert.equal(b.barrier.join_strategy, "all");
  assert.equal(b.max_cost_usd, 1.5);
  assert.equal(b.interface_label, "docker img");
});

test("getProcess returns null on not_found error code", async () => {
  const { adapter } = loadAdapter({
    "processes.get": (_args) => Promise.reject(Object.assign(new Error("nope"), { code: "not_found" }))
  });
  const p = await adapter.getProcess("missing");
  assert.equal(p, null);
});

test("listRuns passes filters to the wire as query args", async () => {
  const { adapter, calls } = loadAdapter({
    "runs.list": { data: [] }
  });
  await adapter.listRuns({ process_name: "x", status: "failed", limit: 50, offset: 100, thread_id: "t1" });
  const c = calls.find((c) => c.method === "runs.list");
  assert.equal(c.args.process, "x");
  assert.equal(c.args.status, "failed");
  assert.equal(c.args.limit, 50);
  assert.equal(c.args.offset, 100);
  assert.equal(c.args.thread_id, "t1");
});

test("status maps daemon payload to view-model with config_drift derived", async () => {
  const { adapter } = loadAdapter({
    "status": {
      version: "1.0", router: "demo", running_commit: 7, startup_commit: 5,
      accepting: true, in_flight: 2, queued: 9
    }
  });
  const s = await adapter.status();
  assert.equal(s.router, "demo");
  assert.equal(s.healthy, true);
  assert.equal(s.core_version, "1.0");
  assert.equal(s.active_commit, 7);
  assert.equal(s.boot_commit, 5);
  assert.equal(s.config_drift, true);   // 7 !== 5 → drift
  assert.equal(s.workers, 2);
  assert.equal(s.queue_depth, 9);
});

test("status returns degraded payload when call fails", async () => {
  const { adapter } = loadAdapter({});  // no stub → call rejects
  const s = await adapter.status();
  assert.equal(s.healthy, false);
  assert.equal(s.workers, 0);
  assert.equal(s.queue_depth, 0);
});

test("triggerProcess maps run_id from data envelope to run_uid", async () => {
  const { adapter } = loadAdapter({
    "processes.trigger": { data: { run_id: "run_123", status: "queued" } }
  });
  const r = await adapter.triggerProcess("p", { type: "x" });
  assert.equal(r.run_uid, "run_123");
});

test("triggerProcess maps not_found code to friendly error message", async () => {
  const { adapter } = loadAdapter({
    "processes.trigger": (_args) => Promise.reject(Object.assign(new Error(""), { code: "not_found" }))
  });
  const r = await adapter.triggerProcess("nope", {});
  assert.match(r.error, /not in the active config/);
});

test("resumeRunByThread mirrors resumeRun shape but keys on thread_id", async () => {
  const { adapter, calls } = loadAdapter({
    "runs.resume_by_thread": { data: { run_id: "r1", status: "success", thread_id: "t1" } }
  });
  const r = await adapter.resumeRunByThread("t1", { decision: "approve" });
  const c = calls.find((c) => c.method === "runs.resume_by_thread");
  assert.equal(c.args.thread_id, "t1");
  assert.deepEqual(c.args.value, { decision: "approve" });
  assert.equal(r.run_uid, "r1");
  assert.equal(r.thread_id, "t1");
});

test("getStep parses input/output JSON from string-encoded wire fields", async () => {
  const { adapter } = loadAdapter({
    "runs.get": {
      data: {
        uid: "r", steps: [{
          id: 7, block_name: "b", status: "success", attempt: 1,
          input_json: '{"hello":"world"}',
          output_json: '{"tool_calls":[{"name":"t","input":{},"output":{}}]}'
        }]
      }
    }
  });
  const s = await adapter.getStep("r", 7);
  assert.deepEqual(s.input_json, { hello: "world" });
  assert.equal(s.output_json.tool_calls[0].name, "t");
});

test("artifactDownloadUrl delegates to ProuterdCore.downloadUrl", () => {
  const { adapter } = loadAdapter({});
  const url = adapter.artifactDownloadUrl(42);
  assert.equal(url, "http://x:1/v1/artifacts/42/download");
});

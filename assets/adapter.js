// adapter.js
//
// JS port of HttpApiAdapter shaping — turns raw /v1/* JSON into the
// view-model objects window renderers consume. Mirrors the Ruby version
// 1:1 in field names so renderers can be a near-direct port of the old
// ERB templates.

(function () {
  "use strict";

  const C = window.ProuterdCore;

  // ----- helpers -----
  function safeInt(v) { return typeof v === "number" ? v : 0; }
  function shortChecksum(s) { return String(s || "").replace(/^sha256:/, "").slice(0, 12); }
  function drift(a, b) {
    if (a == null && b == null) return false;
    if ((a == null) !== (b == null)) return true;
    return a !== b;
  }
  function terminal(status) { return status === "success" || status === "failed" || status === "canceled"; }

  function commitSummary(c) {
    if (!c) return null;
    return {
      id: c.id, checksum: c.checksum, short_checksum: shortChecksum(c.checksum),
      author: c.author, message: c.message, created_at: c.created_at
    };
  }

  function formatValue(v) {
    if (v == null) return "null";
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    return JSON.stringify(v);
  }
  function matchToString(m) {
    const op = m.operator, path = m.path, vals = m.values || [];
    if (op === "exists") return path;
    if (op === "in") return path + " in [" + vals.map(formatValue).join(", ") + "]";
    return path + " " + op + " " + formatValue(vals[0]);
  }
  function matchesToCondition(matches) {
    if (!matches || matches.length === 0) return null;
    return matches.map(matchToString).join(" AND ");
  }

  function summarizeCallFields(ifaceType, fields) {
    if (!fields || Object.keys(fields).length === 0) return null;
    function clip(s) { return s && s.length > 80 ? s.slice(0, 80) + "…" : (s || null); }
    switch (ifaceType) {
      case "shell":  return fields.exec || null;
      case "docker": return fields.command || null;
      case "http": {
        const s = [fields.method, fields.path].filter(Boolean).join(" ").trim();
        return s || null;
      }
      case "llm":      return clip(fields.prompt);
      case "postgres": return clip(fields.query);
      default: {
        const entries = Object.entries(fields).slice(0, 2);
        return entries.length ? entries.map(function (kv) { return kv[0] + "=" + kv[1]; }).join(" ") : null;
      }
    }
  }

  function blockToHash(b) {
    const iface = b.interface || {};
    const cf = b.call_fields || {};
    return {
      name: b.name,
      interface_type: iface.type, interface_name: iface.name,
      interface_label: (iface.type && iface.name) ? iface.type + " " + iface.name : null,
      call_fields: cf,
      call_summary: summarizeCallFields(iface.type, cf),
      timeout_ms: b.timeout_ms, retry_policy: b.retry_policy,
      contract: b.contract, secret_names: b.secret_names || [],
      status: b.shutdown ? "disabled" : "ready"
    };
  }
  function processRouteToHash(r, processName) {
    return {
      from: r.from, to: r.to,
      condition: matchesToCondition(r.matches),
      enabled: r.shutdown !== true, on_failure: r.on_failure,
      process: processName
    };
  }
  function runToHash(r) {
    return {
      run_uid: r.uid, process_name: r.process_name, status: r.status,
      duration_ms: r.duration_ms, started_at: r.started_at, finished_at: r.finished_at,
      config_commit: r.commit_id, trigger: r.interface_name, replay_of: r.replay_of_uid
    };
  }
  function stepToHash(s) {
    return {
      id: s.id, block_name: s.block_name, status: s.status, attempt: s.attempt,
      image: s.image, exit_code: s.exit_code, error_type: s.error_type,
      error_message: s.error_message,
      started_at: s.started_at, finished_at: s.finished_at, duration_ms: s.duration_ms
    };
  }

  // ----- public API methods -----

  async function status() {
    const startedAt = window.ProuterdAdapter._startedAt || (window.ProuterdAdapter._startedAt = Date.now());
    try {
      const p = await C.fetchJson("/v1/status");
      return {
        router: p.router || "prouterd",
        healthy: p.accepting !== false,
        core_version: p.version,
        active_commit: p.running_commit,
        boot_commit: p.startup_commit,
        config_drift: drift(p.running_commit, p.startup_commit),
        workers: p.in_flight || 0,
        queue_depth: safeInt(p.queued),
        failed_runs_last_hour: 0,
        uptime_seconds: Math.floor((Date.now() - startedAt) / 1000),
        db_path: null, artifact_path: null
      };
    } catch (e) {
      return {
        router: "prouterd", healthy: false, core_version: null,
        active_commit: null, boot_commit: null, config_drift: false,
        workers: 0, queue_depth: 0, failed_runs_last_hour: 0,
        uptime_seconds: Math.floor((Date.now() - startedAt) / 1000),
        db_path: null, artifact_path: null
      };
    }
  }

  async function listProcesses() {
    const data = (await C.fetchJson("/v1/processes")).data || [];
    return data.map(function (p) {
      return {
        name: p.name, status: p.shutdown ? "disabled" : "enabled",
        blocks: p.blocks, routes: p.routes, queue: p.queue,
        last_status: null, success_rate: null
      };
    });
  }

  async function getProcess(name) {
    let payload;
    try { payload = (await C.fetchJson("/v1/processes/" + encodeURIComponent(name))).data; }
    catch (e) { if (e.status === 404) return null; throw e; }
    return {
      name: payload.name, description: payload.description,
      status: payload.shutdown ? "disabled" : "enabled",
      queue: payload.queue,
      entry_block: (payload.blocks || [])[0] && payload.blocks[0].name,
      last_status: null, success_rate: null,
      blocks: (payload.blocks || []).map(blockToHash),
      routes: (payload.routes || []).map(function (r) { return processRouteToHash(r, payload.name); })
    };
  }

  async function listRoutes(processName) {
    if (processName) {
      const p = await getProcess(processName);
      return p ? p.routes : [];
    }
    const procs = await listProcesses();
    const out = [];
    for (const p of procs) {
      const detail = await getProcess(p.name);
      if (detail) for (const r of detail.routes) out.push(r);
    }
    return out;
  }

  async function listBlocks() {
    const procs = await listProcesses();
    const out = [];
    for (const p of procs) {
      const detail = await getProcess(p.name);
      if (!detail) continue;
      for (const b of detail.blocks) out.push(Object.assign({ process: p.name }, b));
    }
    return out;
  }

  async function listInterfaces() {
    const data = (await C.fetchJson("/v1/interfaces")).data || [];
    return data.map(function (i) {
      return {
        name: i.name, kind: i.type, direction: i.direction,
        status: i.shutdown ? "disabled" : "enabled",
        fields: i.fields || {}
      };
    });
  }
  async function listQueues() {
    const data = (await C.fetchJson("/v1/queues")).data || [];
    return data.map(function (q) {
      return { name: q.name, concurrency: q.concurrency, timeout_ms: q.timeout_ms };
    });
  }
  async function listPolicies() {
    const data = (await C.fetchJson("/v1/policies")).data || [];
    return data.map(function (p) {
      return {
        name: p.name, retry_attempts: p.retry_attempts, retry_backoff: p.retry_backoff,
        retry_initial_delay_ms: p.retry_initial_delay_ms,
        retry_max_delay_ms: p.retry_max_delay_ms,
        retry_when: p.retry_when, timeout_ms: p.timeout_ms
      };
    });
  }
  async function listSecrets() {
    const data = (await C.fetchJson("/v1/secrets")).data || [];
    return data.map(function (s) {
      return {
        name: s.name, source_type: s.source_type, source_ref: s.source_ref,
        used_by: s.used_by || [], status: s.status
      };
    });
  }

  async function listRuns(filters) {
    filters = filters || {};
    const q = new URLSearchParams();
    if (filters.process_name || filters.process) q.set("process", filters.process_name || filters.process);
    if (filters.status) q.set("status", filters.status);
    if (filters.limit  != null) q.set("limit",  filters.limit);
    if (filters.offset != null) q.set("offset", filters.offset);
    const path = "/v1/runs" + (q.toString() ? "?" + q.toString() : "");
    const rows = (await C.fetchJson(path)).data || [];
    return rows.map(runToHash);
  }

  async function getRun(uid) {
    let payload;
    try { payload = (await C.fetchJson("/v1/runs/" + encodeURIComponent(uid))).data; }
    catch (e) { if (e.status === 404) return null; throw e; }
    const base = runToHash(payload);
    return Object.assign(base, {
      interface_name: payload.interface_name,
      error_summary:  payload.error_summary,
      replayable:     terminal(payload.status)
    });
  }
  async function getRunSteps(uid) {
    let payload;
    try { payload = (await C.fetchJson("/v1/runs/" + encodeURIComponent(uid))).data; }
    catch (e) { if (e.status === 404) return []; throw e; }
    return (payload.steps || []).map(stepToHash);
  }

  async function activeConfig() {
    const rendered = await C.fetchJson("/v1/config/running").catch(function () { return null; });
    let payload;
    try { payload = await C.fetchJson("/v1/config/commits"); }
    catch (e) { return null; }
    const runningId = payload && payload.meta && payload.meta.running;
    if (!runningId) return null;
    const c = (payload.data || []).find(function (c) { return c.id === runningId; });
    return { commit: commitSummary(c), rendered: rendered };
  }
  async function bootConfig() {
    let payload;
    try { payload = await C.fetchJson("/v1/config/commits"); }
    catch (e) { return null; }
    const startupId = payload && payload.meta && payload.meta.startup;
    if (!startupId) return null;
    const rendered = await C.fetchJson("/v1/config/startup").catch(function () { return null; });
    const c = (payload.data || []).find(function (c) { return c.id === startupId; });
    return { commit: commitSummary(c), rendered: rendered };
  }
  async function listCommits(limit) {
    limit = limit || 50;
    const data = (await C.fetchJson("/v1/config/commits")).data || [];
    return data.slice(0, limit).map(commitSummary);
  }

  async function getCommit(id) {
    let payload;
    try { payload = (await C.fetchJson("/v1/config/commits/" + encodeURIComponent(id))).data; }
    catch (e) { if (e.status === 404) return null; throw e; }
    return Object.assign(commitSummary(payload), { rendered: payload.rendered_config });
  }

  async function configDiff(left, right) {
    const l = await getCommit(left);
    const r = await getCommit(right);
    if (!l || !r) return null;
    return {
      left:  l, right: r,
      rows:  window.ProuterdDiff.lines(l.rendered || "", r.rendered || "")
    };
  }

  async function countRuns(filters) {
    filters = filters || {};
    const q = new URLSearchParams();
    if (filters.process_name || filters.process) q.set("process", filters.process_name || filters.process);
    q.set("limit", "1000");
    const path = "/v1/runs?" + q.toString();
    return ((await C.fetchJson(path)).data || []).length;
  }

  async function getStep(uid, stepId) {
    let payload;
    try { payload = (await C.fetchJson("/v1/runs/" + encodeURIComponent(uid))).data; }
    catch (e) { if (e.status === 404) return null; throw e; }
    const step = (payload.steps || []).find(function (s) { return s.id === Number(stepId); });
    if (!step) return null;
    return Object.assign(stepToHash(step), {
      input_json:  parseJsonMaybe(step.input_json),
      output_json: parseJsonMaybe(step.output_json)
    });
  }

  async function getRunContext(uid) {
    let payload;
    try { payload = (await C.fetchJson("/v1/runs/" + encodeURIComponent(uid))).data; }
    catch (e) { if (e.status === 404) return null; throw e; }
    return {
      input_event: parseJsonMaybe(payload.input_event_json),
      context:     parseJsonMaybe(payload.context_json)
    };
  }

  async function getStepLogs(uid, opts) {
    opts = opts || {};
    const q = new URLSearchParams();
    if (opts.step_id  != null) q.set("step",  opts.step_id);
    if (opts.after_id != null) q.set("after", opts.after_id);
    const path = "/v1/runs/" + encodeURIComponent(uid) + "/logs" +
                 (q.toString() ? "?" + q.toString() : "");
    let rows;
    try { rows = (await C.fetchJson(path)).data || []; }
    catch (e) { if (e.status === 404) return []; throw e; }
    return rows.map(function (l) {
      return {
        id: l.id, run_id: l.run_id, step_id: l.step_id,
        stream: l.stream, content: l.content, created_at: l.created_at
      };
    });
  }

  async function getRunArtifacts(uid, opts) {
    opts = opts || {};
    let rows;
    try { rows = (await C.fetchJson("/v1/runs/" + encodeURIComponent(uid) + "/artifacts")).data || []; }
    catch (e) { if (e.status === 404) return []; throw e; }
    if (opts.step_id != null) {
      const sid = Number(opts.step_id);
      rows = rows.filter(function (a) { return a.step_id === sid; });
    }
    return rows.map(function (a) {
      return {
        id: a.id, step_id: a.step_id, block_name: a.block_name, name: a.name,
        size_bytes: a.size_bytes, content_type: a.content_type,
        checksum: a.checksum, created_at: a.created_at, path: a.path
      };
    });
  }

  function artifactDownloadUrl(id) {
    const cfg = C.config();
    if (!cfg.url) return "";
    let url = cfg.url + "/v1/artifacts/" + encodeURIComponent(id) + "/download";
    if (cfg.token) url += "?token=" + encodeURIComponent(cfg.token);
    return url;
  }

  async function traceEvent(eventJson, interfaceName) {
    const body = { event: eventJson || {} };
    if (interfaceName) body.interface = interfaceName;
    try {
      const p = await C.fetchJson("/v1/trace", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      return p && p.data ? p.data : {};
    } catch (e) { return { error: e.message }; }
  }

  // ----- actions -----
  async function triggerProcess(name, event) {
    try {
      const p = await C.fetchJson("/v1/processes/" + encodeURIComponent(name) + "/trigger", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(event || {})
      });
      const uid = p && p.data && p.data.run_id;
      return uid ? { run_uid: uid } : { error: (p && p.error) || "trigger failed" };
    } catch (e) {
      if (e.status === 404) return { error: "process '" + name + "' is not in the active config" };
      return { error: e.message };
    }
  }
  async function cancelRun(uid) {
    try { await C.fetchJson("/v1/runs/" + encodeURIComponent(uid) + "/cancel", { method: "POST" }); return true; }
    catch (e) { return false; }
  }
  async function rollbackConfig(commitId) {
    try {
      const p = await C.fetchJson("/v1/config/rollback", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ commit_id: Number(commitId) })
      });
      const data = p && p.data;
      if (!data) return null;
      return { id: data.commit_id, short_checksum: shortChecksum(data.checksum) };
    } catch (e) { if (e.status === 404) return null; return null; }
  }

  async function saveBootConfig() {
    try {
      const p = await C.fetchJson("/v1/config/save-boot", { method: "POST" });
      const data = p && p.data;
      if (!data) return null;
      return { id: data.commit_id, short_checksum: shortChecksum(data.checksum) };
    } catch (e) { return null; }
  }

  function parseJsonMaybe(value) {
    if (value == null) return null;
    if (typeof value === "object") return value;
    if (typeof value !== "string" || value === "") return null;
    try { return JSON.parse(value); }
    catch (e) { return value; }
  }

  async function replayRun(uid, fromBlock) {
    const body = {};
    if (fromBlock) body.from_block = fromBlock;
    try {
      const p = await C.fetchJson("/v1/runs/" + encodeURIComponent(uid) + "/replay", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const newUid = p && p.data && p.data.run_id;
      if (newUid) return { run_uid: newUid, replay_of: uid, from_block: fromBlock };
      return { error: (p && p.error) || "replay failed" };
    } catch (e) {
      if (e.status === 404) return null;
      return { error: e.message };
    }
  }

  window.ProuterdAdapter = {
    status: status,
    listProcesses: listProcesses, getProcess: getProcess,
    listRoutes: listRoutes, listBlocks: listBlocks,
    listInterfaces: listInterfaces, listQueues: listQueues,
    listPolicies: listPolicies, listSecrets: listSecrets,
    listRuns: listRuns, countRuns: countRuns,
    getRun: getRun, getRunSteps: getRunSteps,
    getStep: getStep, getRunContext: getRunContext,
    getStepLogs: getStepLogs, getRunArtifacts: getRunArtifacts,
    artifactDownloadUrl: artifactDownloadUrl,
    activeConfig: activeConfig, bootConfig: bootConfig,
    listCommits: listCommits, getCommit: getCommit, configDiff: configDiff,
    triggerProcess: triggerProcess, cancelRun: cancelRun, replayRun: replayRun,
    rollbackConfig: rollbackConfig, saveBootConfig: saveBootConfig,
    traceEvent: traceEvent
  };
})();

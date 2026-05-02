// window_manager.js — Phase UI-2.
//
// Vanilla JS, no build step. Owns the workspace: opening windows, focus /
// z-order, drag-to-move (header), drag-to-resize (corner handle),
// minimize / maximize / restore, taskbar entries, and layout persistence
// to localStorage. Window body content is fetched from
// `GET /windows/:type[/:resource_id]` over plain HTTP — Phase UI-6 will
// add WebSocket `window.render` / `window.patch` on top of this.

(function () {
  "use strict";

  const STORAGE_KEY = "prouterd.web.layout.v1";
  const MIN_W = 280;
  const MIN_H = 160;
  const TYPE_SIZES = {
    logs: { width: 880, height: 520 },
    step: { width: 880, height: 540 },
    context: { width: 720, height: 540 },
    artifacts: { width: 820, height: 380 },
    run: { width: 880, height: 520 },
    config: { width: 920, height: 580 },
    diff: { width: 880, height: 540 },
    cli: { width: 760, height: 460 },
    trace: { width: 760, height: 580 }
  };

  const TYPE_TITLES = {
    system: "System Status",
    processes: "Processes",
    process: "Process",
    runs: "Runs",
    run: "Run",
    step: "Step",
    interfaces: "Interfaces",
    routes: "Routes",
    blocks: "Blocks",
    queues: "Queues",
    policies: "Policies",
    secrets: "Secrets",
    config: "Config",
    diff:  "Config diff",
    trace: "Trace event",
    logs: "Logs",
    context: "Context",
    artifacts: "Artifacts",
    cli: "CLI"
  };

  const state = {
    windows: new Map(),
    nextZ: 10,
    cascadeStep: 0,
    workspace: null,
    placeholder: null,
    taskbarEntries: null,
    taskbarEmpty: null
  };

  // Public surface for object-tree / future palette / debugging.
  window.ProuterdWM = {
    open, close, focus, minimize, maximize, restore, reset, refresh, state
  };

  async function refresh(id) {
    const ws = state.windows.get(id);
    if (!ws) return;
    await hydrateBody(ws);
  }

  document.addEventListener("DOMContentLoaded", init);

  function init() {
    state.workspace      = document.getElementById("workspace");
    state.placeholder    = document.getElementById("workspace-placeholder");
    state.taskbarEntries = document.getElementById("taskbar-entries");
    state.taskbarEmpty   = document.getElementById("taskbar-empty");
    if (!state.workspace) return;

    const tree = document.querySelector(".object-tree");
    if (tree) {
      tree.addEventListener("click", function (e) {
        const link = e.target.closest("a[data-window-type]");
        if (!link) return;
        e.preventDefault();
        const type = link.dataset.windowType;

        // CLI windows are session-scoped: each new tree-click spawns a
        // fresh session id so an operator can keep multiple shells side
        // by side. Reopening a layout from localStorage reuses the saved
        // resource id, so the same session resumes after reload.
        if (type === "cli") {
          open(type, newSessionId());
        } else {
          open(type);
        }
      });
    }

    const resetBtn = document.getElementById("reset-workspace-btn");
    if (resetBtn) {
      resetBtn.addEventListener("click", function () {
        if (confirm("Reset workspace? All windows will be closed and saved layout cleared.")) {
          reset();
        }
      });
    }

    // Delegated handlers for: drill-down ([data-open-window]/[data-open-resource]),
    // per-window tab switching ([data-tab] toggling [data-tab-panel]),
    // and write-side config actions ([data-config-action]).
    document.addEventListener("click", function (e) {
      const drill = e.target.closest("[data-open-window]");
      if (drill && !drill.disabled) {
        e.preventDefault();
        open(drill.dataset.openWindow, drill.dataset.openResource || null);
        return;
      }

      const tab = e.target.closest("[data-tab]");
      if (tab) {
        const win = tab.closest(".window");
        if (!win) return;
        const tabId = tab.dataset.tab;
        win.querySelectorAll("[data-tab]").forEach(function (t) {
          if (t.closest(".window") !== win) return;
          t.classList.toggle("tab--active", t.dataset.tab === tabId);
        });
        win.querySelectorAll("[data-tab-panel]").forEach(function (p) {
          if (p.closest(".window") !== win) return;
          p.hidden = (p.dataset.tabPanel !== tabId);
        });
        return;
      }

      const cfgAction = e.target.closest("[data-config-action]");
      if (cfgAction && !cfgAction.disabled) {
        e.preventDefault();
        runConfigAction(cfgAction);
        return;
      }

      const runAction = e.target.closest("[data-run-action]");
      if (runAction && !runAction.disabled) {
        e.preventDefault();
        runRunAction(runAction);
        return;
      }

      const trigAction = e.target.closest("[data-trigger-action]");
      if (trigAction && !trigAction.disabled) {
        e.preventDefault();
        runTriggerAction(trigAction);
        return;
      }

      const pageLink = e.target.closest("[data-page-link]");
      if (pageLink && !pageLink.disabled) {
        e.preventDefault();
        const winEl = pageLink.closest(".window");
        if (!winEl) return;
        loadIntoWindow(winEl, pageLink.dataset.pageLink);
        return;
      }

      const traceAction = e.target.closest("[data-trace-action]");
      if (traceAction && !traceAction.disabled) {
        e.preventDefault();
        runTraceAction(traceAction);
      }
    });

    loadLayout();
    updateTaskbar();
  }

  // ----- open / close -----

  async function open(type, resourceId) {
    const id = windowIdFor(type, resourceId);

    if (state.windows.has(id)) {
      const ws = state.windows.get(id);
      if (ws.state === "minimized") restore(id);
      else focus(id);
      return ws;
    }

    const cascade = (state.cascadeStep++) % 8;
    const size = TYPE_SIZES[type] || { width: 720, height: 460 };
    const ws = {
      id: id,
      type: type,
      resourceId: resourceId || null,
      title: titleFor(type, resourceId),
      x: 80 + cascade * 24,
      y: 60 + cascade * 24,
      width: size.width,
      height: size.height,
      state: "normal",
      z: ++state.nextZ,
      prevRect: null,
      bodyHtml: '<div class="window__loading">loading…</div>'
    };

    state.windows.set(id, ws);
    renderWindow(ws);
    focus(id);
    updateTaskbar();
    saveLayout();

    hydrateBody(ws);
    attachLiveSubscriptions(ws);
    return ws;
  }

  function close(id) {
    const ws = state.windows.get(id);
    if (!ws) return;
    detachLiveSubscriptions(ws);
    const el = document.getElementById(id);
    if (el) el.remove();
    state.windows.delete(id);
    updateTaskbar();
    saveLayout();
  }

  // ----- live updates (Phase UI-6) -----
  //
  // Each open window subscribes to the topics relevant to its content.
  // Incoming events trigger a debounced full re-hydrate of the window
  // body — Phase UI-9 may swap in incremental patches for the log
  // viewer, but for everything else a full re-fetch is plenty.

  function topicsForWindow(ws) {
    switch (ws.type) {
      case "system":     return ["system"];
      case "processes":  return ["runs"];
      case "runs":       return ["runs"];
      case "run":        return ws.resourceId ? ["run:" + ws.resourceId] : [];
      case "step": {
        const runUid = (ws.resourceId || "").split("/")[0];
        return runUid ? ["run:" + runUid, "logs:" + runUid] : [];
      }
      case "logs":       return ws.resourceId ? ["logs:" + ws.resourceId] : [];
      case "context":    return ws.resourceId ? ["run:" + ws.resourceId] : [];
      case "artifacts":  return ws.resourceId ? ["run:" + ws.resourceId] : [];
      case "config":     return ["system"];
      case "diff":       return ["system"];
      default:           return [];
    }
  }

  function attachLiveSubscriptions(ws) {
    if (typeof window.ProuterdWS === "undefined") return;
    const topics = topicsForWindow(ws);
    if (topics.length === 0) return;

    const refresh = debounce(function () {
      const cur = state.windows.get(ws.id);
      if (cur) hydrateBody(cur);
    }, 250);

    ws.unsubscribers = topics.map(function (topic) {
      return window.ProuterdWS.subscribe(topic, refresh);
    });
  }

  function detachLiveSubscriptions(ws) {
    if (!ws.unsubscribers) return;
    ws.unsubscribers.forEach(function (u) { try { u(); } catch (e) { /* ignore */ } });
    ws.unsubscribers = null;
  }

  function debounce(fn, wait) {
    let t = null;
    return function () {
      if (t) clearTimeout(t);
      t = setTimeout(function () { t = null; fn(); }, wait);
    };
  }

  // ----- focus / z-order -----

  function focus(id) {
    const ws = state.windows.get(id);
    if (!ws || ws.state === "minimized") return;
    ws.z = ++state.nextZ;
    document.querySelectorAll(".window--focused").forEach(function (el) {
      el.classList.remove("window--focused");
    });
    const el = document.getElementById(id);
    if (el) {
      el.style.zIndex = String(ws.z);
      el.classList.add("window--focused");
    }
    updateTaskbar();
  }

  // ----- minimize / maximize / restore -----

  function minimize(id) {
    const ws = state.windows.get(id);
    if (!ws) return;
    ws.state = "minimized";
    const el = document.getElementById(id);
    if (el) el.classList.add("window--minimized");
    updateTaskbar();
    saveLayout();
  }

  function maximize(id) {
    const ws = state.windows.get(id);
    if (!ws) return;
    if (ws.state === "maximized") { restore(id); return; }
    ws.prevRect = { x: ws.x, y: ws.y, width: ws.width, height: ws.height };
    ws.state = "maximized";
    const el = document.getElementById(id);
    if (el) el.classList.add("window--maximized");
    focus(id);
    saveLayout();
  }

  function restore(id) {
    const ws = state.windows.get(id);
    if (!ws) return;

    if (ws.state === "minimized") {
      ws.state = "normal";
      const el = document.getElementById(id);
      if (el) el.classList.remove("window--minimized");
    } else if (ws.state === "maximized") {
      ws.state = "normal";
      if (ws.prevRect) {
        ws.x = ws.prevRect.x; ws.y = ws.prevRect.y;
        ws.width = ws.prevRect.width; ws.height = ws.prevRect.height;
        ws.prevRect = null;
      }
      const el = document.getElementById(id);
      if (el) {
        el.classList.remove("window--maximized");
        applyRect(el, ws);
      }
    }
    focus(id);
    updateTaskbar();
    saveLayout();
  }

  // ----- reset -----

  function reset() {
    Array.from(state.windows.keys()).forEach(function (id) {
      const el = document.getElementById(id);
      if (el) el.remove();
    });
    state.windows.clear();
    state.nextZ = 10;
    state.cascadeStep = 0;
    try { localStorage.removeItem(STORAGE_KEY); } catch (e) { /* ignore */ }
    updateTaskbar();
  }

  // ----- DOM -----

  function renderWindow(ws) {
    const el = document.createElement("section");
    el.className = "window";
    el.id = ws.id;
    if (ws.state === "maximized") el.classList.add("window--maximized");
    if (ws.state === "minimized") el.classList.add("window--minimized");
    el.innerHTML =
      '<header class="window__header">' +
        '<span class="window__title"></span>' +
        '<span class="window__controls">' +
          '<button type="button" data-action="minimize" title="Minimize">−</button>' +
          '<button type="button" data-action="maximize" title="Maximize / restore">▢</button>' +
          '<button type="button" data-action="close"    title="Close">×</button>' +
        '</span>' +
      '</header>' +
      '<div class="window__body"></div>' +
      '<span class="window__resize" data-action="resize"></span>';

    el.querySelector(".window__title").textContent = ws.title;
    el.querySelector(".window__body").innerHTML = ws.bodyHtml || "";
    applyRect(el, ws);
    el.style.zIndex = String(ws.z);

    state.workspace.appendChild(el);
    attachEventHandlers(el, ws.id);
    updatePlaceholderVisibility();
  }

  function applyRect(el, ws) {
    el.style.left   = ws.x + "px";
    el.style.top    = ws.y + "px";
    el.style.width  = ws.width + "px";
    el.style.height = ws.height + "px";
  }

  function attachEventHandlers(el, id) {
    el.addEventListener("pointerdown", function () { focus(id); }, true);

    el.querySelector("[data-action='close']").addEventListener("click", function (e) {
      e.stopPropagation();
      close(id);
    });
    el.querySelector("[data-action='minimize']").addEventListener("click", function (e) {
      e.stopPropagation();
      minimize(id);
    });
    el.querySelector("[data-action='maximize']").addEventListener("click", function (e) {
      e.stopPropagation();
      const ws = state.windows.get(id);
      if (!ws) return;
      ws.state === "maximized" ? restore(id) : maximize(id);
    });

    attachDrag(el.querySelector(".window__header"), id);
    attachResize(el.querySelector(".window__resize"), id);
  }

  function attachDrag(headerEl, id) {
    let startX = 0, startY = 0, origX = 0, origY = 0, dragging = false;

    headerEl.addEventListener("pointerdown", function (e) {
      if (e.target.closest("button")) return;
      const ws = state.windows.get(id);
      if (!ws || ws.state !== "normal") return;
      dragging = true;
      startX = e.clientX; startY = e.clientY;
      origX = ws.x; origY = ws.y;
      headerEl.setPointerCapture(e.pointerId);
      e.preventDefault();
    });
    headerEl.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      const ws = state.windows.get(id);
      if (!ws) return;
      ws.x = Math.max(0, origX + (e.clientX - startX));
      ws.y = Math.max(0, origY + (e.clientY - startY));
      const el = document.getElementById(id);
      if (el) applyRect(el, ws);
    });
    headerEl.addEventListener("pointerup", function () {
      if (!dragging) return;
      dragging = false;
      saveLayout();
    });
    headerEl.addEventListener("pointercancel", function () { dragging = false; });
  }

  function attachResize(handleEl, id) {
    let startX = 0, startY = 0, origW = 0, origH = 0, resizing = false;

    handleEl.addEventListener("pointerdown", function (e) {
      const ws = state.windows.get(id);
      if (!ws || ws.state !== "normal") return;
      resizing = true;
      startX = e.clientX; startY = e.clientY;
      origW = ws.width; origH = ws.height;
      handleEl.setPointerCapture(e.pointerId);
      e.stopPropagation();
      e.preventDefault();
    });
    handleEl.addEventListener("pointermove", function (e) {
      if (!resizing) return;
      const ws = state.windows.get(id);
      if (!ws) return;
      ws.width  = Math.max(MIN_W, origW + (e.clientX - startX));
      ws.height = Math.max(MIN_H, origH + (e.clientY - startY));
      const el = document.getElementById(id);
      if (el) applyRect(el, ws);
    });
    handleEl.addEventListener("pointerup", function () {
      if (!resizing) return;
      resizing = false;
      saveLayout();
    });
    handleEl.addEventListener("pointercancel", function () { resizing = false; });
  }

  function updatePlaceholderVisibility() {
    if (!state.placeholder) return;
    state.placeholder.style.display = state.windows.size === 0 ? "" : "none";
  }

  function updateTaskbar() {
    if (!state.taskbarEntries || !state.taskbarEmpty) return;
    state.taskbarEntries.innerHTML = "";

    const arr = Array.from(state.windows.values());
    arr.sort(function (a, b) { return a.id.localeCompare(b.id); });

    if (arr.length === 0) {
      state.taskbarEmpty.style.display = "";
    } else {
      state.taskbarEmpty.style.display = "none";

      let focused = null;
      for (const ws of arr) {
        if (ws.state === "minimized") continue;
        if (focused === null || ws.z > focused.z) focused = ws;
      }

      for (const ws of arr) {
        const entry = document.createElement("button");
        entry.type = "button";
        entry.className = "taskbar__entry";
        if (ws.state === "minimized") entry.classList.add("taskbar__entry--minimized");
        if (focused && ws.id === focused.id) entry.classList.add("taskbar__entry--focused");
        entry.textContent = ws.title;
        entry.title = ws.title;
        entry.addEventListener("click", function () {
          const w = state.windows.get(ws.id);
          if (!w) return;
          if (w.state === "minimized") restore(w.id);
          else if (focused && w.id === focused.id) minimize(w.id);
          else focus(w.id);
        });
        state.taskbarEntries.appendChild(entry);
      }
    }
    updatePlaceholderVisibility();
  }

  function titleFor(type, resourceId) {
    const base = TYPE_TITLES[type] || type;
    return resourceId ? base + ": " + resourceId : base;
  }

  // Resource IDs may carry "/" separators (e.g. "run_18492/4" for steps).
  // For the URL we percent-encode each segment but preserve slashes so the
  // route can split on them. For the DOM id we collapse non-id characters.
  function urlFor(type, resourceId) {
    if (!resourceId) return "/windows/" + type;
    const segs = resourceId.split("/").map(encodeURIComponent).join("/");
    return "/windows/" + type + "/" + segs;
  }

  function windowIdFor(type, resourceId) {
    if (!resourceId) return "win_" + type;
    const safe = resourceId.replace(/[^A-Za-z0-9_-]/g, "_");
    return "win_" + type + "_" + safe;
  }

  function newSessionId() {
    if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
      return "cli-" + crypto.randomUUID();
    }
    return "cli-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  // ----- persistence -----

  function saveLayout() {
    const data = {
      windows: Array.from(state.windows.values()).map(function (ws) {
        return {
          id: ws.id, type: ws.type, resourceId: ws.resourceId, title: ws.title,
          x: ws.x, y: ws.y, width: ws.width, height: ws.height,
          state: ws.state, z: ws.z, prevRect: ws.prevRect,
          contentUrl: ws.contentUrl || null
        };
      })
    };
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(data)); }
    catch (e) { /* quota / private mode — best effort */ }
  }

  function loadLayout() {
    let raw;
    try { raw = localStorage.getItem(STORAGE_KEY); } catch (e) { return; }
    if (!raw) return;

    let data;
    try { data = JSON.parse(raw); }
    catch (e) {
      try { localStorage.removeItem(STORAGE_KEY); } catch (_) { /* ignore */ }
      return;
    }

    const wins = (data && data.windows) || [];
    for (const ws of wins) {
      ws.bodyHtml = '<div class="window__loading">loading…</div>';
      state.windows.set(ws.id, ws);
      if (ws.z > state.nextZ) state.nextZ = ws.z;
      renderWindow(ws);
      hydrateBody(ws);
      attachLiveSubscriptions(ws);
    }
  }

  async function runConfigAction(el) {
    const action = el.dataset.configAction;
    const confirmText = el.dataset.confirm;
    if (confirmText && !confirm(confirmText)) return;

    let url;
    if (action === "rollback") {
      const cid = el.dataset.commitId;
      if (!cid) return;
      url = "/actions/config/rollback/" + encodeURIComponent(cid);
    } else if (action === "save-boot") {
      url = "/actions/config/save-boot";
    } else {
      return;
    }

    el.disabled = true;
    try {
      const res = await fetch(url, { method: "POST" });
      const payload = await res.json().catch(function () { return {}; });
      if (!res.ok) {
        alert("Action failed: " + (payload.error || res.statusText));
        return;
      }
      // Refresh the window we're inside (config window typically) plus any
      // others that depend on config state. For UI-5 we just refresh all
      // open windows whose type is config / system / diff so drift / commit
      // pointer changes propagate.
      Array.from(state.windows.values())
        .filter(function (ws) { return ws.type === "config" || ws.type === "system" || ws.type === "diff"; })
        .forEach(function (ws) { hydrateBody(ws); });
    } catch (err) {
      alert("Action failed: " + err.message);
    } finally {
      el.disabled = false;
    }
  }

  async function runRunAction(el) {
    const action = el.dataset.runAction;
    const uid    = el.dataset.runUid;
    if (!action || !uid) return;

    const confirmText = el.dataset.confirm;
    if (confirmText && !confirm(confirmText)) return;

    let url, body;
    if (action === "cancel") {
      url = "/actions/runs/cancel/" + encodeURIComponent(uid);
    } else if (action === "replay") {
      url = "/actions/runs/replay/" + encodeURIComponent(uid);
      body = JSON.stringify({});
    } else if (action === "replay-from") {
      const block = el.dataset.fromBlock;
      if (!block) return;
      url  = "/actions/runs/replay/" + encodeURIComponent(uid);
      body = JSON.stringify({ from_block: block });
    } else {
      return;
    }

    el.disabled = true;
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: body ? { "Content-Type": "application/json" } : {},
        body: body
      });
      const payload = await res.json().catch(function () { return {}; });
      if (!res.ok) {
        alert(action + " failed: " + (payload.error || res.statusText));
        return;
      }

      // Refresh the window we acted from + the runs list. Live updates will
      // pick up further state changes (run.created / step.* / run.updated).
      Array.from(state.windows.values())
        .filter(function (ws) { return ws.type === "runs" || ws.type === "run" || ws.type === "system"; })
        .forEach(function (ws) { hydrateBody(ws); });

      // Replay produced a new run — open it so the operator can watch.
      if ((action === "replay" || action === "replay-from") && payload.run_uid) {
        open("run", payload.run_uid);
      }
    } catch (err) {
      alert(action + " failed: " + err.message);
    } finally {
      el.disabled = false;
    }
  }

  async function runTriggerAction(el) {
    const action = el.dataset.triggerAction;
    const form   = el.closest(".trigger-form");
    if (!form) return;
    const ta     = form.querySelector(".trigger-form__input");
    const status = form.querySelector(".trigger-form__status");
    const proc   = form.dataset.triggerProcess;
    if (!ta || !status || !proc) return;

    let parsed;
    try { parsed = JSON.parse(ta.value); }
    catch (e) {
      status.textContent = "JSON parse error: " + e.message;
      status.className = "trigger-form__status trigger-form__status--error";
      return;
    }

    if (action === "validate") {
      status.textContent = "JSON looks valid (" + (typeof parsed === "object" ? "object" : typeof parsed) + ")";
      status.className = "trigger-form__status trigger-form__status--ok";
      return;
    }

    if (action !== "trigger") return;

    el.disabled = true;
    status.textContent = "triggering…";
    status.className = "trigger-form__status";
    try {
      const res = await fetch("/actions/runs/trigger/" + encodeURIComponent(proc), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input_event: parsed })
      });
      const payload = await res.json().catch(function () { return {}; });
      if (!res.ok || !payload.run_uid) {
        status.textContent = "trigger failed: " + (payload.error || res.statusText);
        status.className = "trigger-form__status trigger-form__status--error";
        return;
      }

      status.textContent = "run created: " + payload.run_uid;
      status.className = "trigger-form__status trigger-form__status--ok";

      Array.from(state.windows.values())
        .filter(function (ws) { return ws.type === "runs"; })
        .forEach(function (ws) { hydrateBody(ws); });
      open("run", payload.run_uid);
    } catch (err) {
      status.textContent = "trigger failed: " + err.message;
      status.className = "trigger-form__status trigger-form__status--error";
    } finally {
      el.disabled = false;
    }
  }

  async function loadIntoWindow(winEl, url) {
    const ws = state.windows.get(winEl.id);
    if (!ws) return;

    ws.contentUrl = url;
    saveLayout();

    const body = winEl.querySelector(".window__body");
    if (body) body.innerHTML = '<div class="window__loading">loading…</div>';

    try {
      const res  = await fetch(url);
      const html = await res.text();
      ws.bodyHtml = html;
      if (body) body.innerHTML = html;
    } catch (e) {
      if (body) body.innerHTML = '<div class="window-error">failed to load</div>';
    }
  }

  async function runTraceAction(el) {
    const action = el.dataset.traceAction;
    const form   = el.closest("[data-trace-form]");
    if (!form) return;

    const eventArea = form.querySelector("[data-trace-event]");
    const ifaceInp  = form.querySelector("[data-trace-interface]");
    const status    = form.querySelector("[data-trace-status]");
    const result    = form.parentElement.querySelector("[data-trace-result]");

    let parsed;
    try { parsed = JSON.parse(eventArea.value); }
    catch (e) {
      status.textContent = "JSON parse error: " + e.message;
      status.className = "trigger-form__status trigger-form__status--error";
      return;
    }

    if (action === "validate") {
      status.textContent = "JSON looks valid (" + (typeof parsed === "object" ? "object" : typeof parsed) + ")";
      status.className = "trigger-form__status trigger-form__status--ok";
      return;
    }

    if (action !== "trace") return;

    el.disabled = true;
    status.textContent = "tracing…";
    status.className = "trigger-form__status";
    if (result) result.innerHTML = "";

    try {
      const body = {
        event: parsed,
        interface_name: (ifaceInp.value || "").trim() || undefined
      };
      const res = await fetch("/actions/trace", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      const payload = await res.json().catch(function () { return {}; });
      if (!res.ok) {
        status.textContent = "trace failed: " + (payload.error || res.statusText);
        status.className = "trigger-form__status trigger-form__status--error";
        return;
      }

      status.textContent = "trace ok";
      status.className = "trigger-form__status trigger-form__status--ok";
      if (result) result.innerHTML = renderTraceTree(payload.data || {});
    } catch (err) {
      status.textContent = "trace failed: " + err.message;
      status.className = "trigger-form__status trigger-form__status--error";
    } finally {
      el.disabled = false;
    }
  }

  function renderTraceTree(data) {
    const lines = [];
    if (data.error) {
      lines.push('<div class="window-error">' + escapeHtml(data.error) + '</div>');
      return lines.join("");
    }

    if (data.global_route !== undefined) {
      lines.push('<div class="trace-section"><div class="trace-section__head">Global route</div>');
      const passes = data.global_route_passes ? "passes" : "blocked";
      const klass  = data.global_route_passes ? "status-success" : "status-failed";
      const gr = data.global_route || {};
      lines.push('<div class="trace-row"><span class="' + klass + '">' + passes + '</span> ' +
                 escapeHtml(gr.from || gr.from_interface || "?") + " → " +
                 escapeHtml(gr.to || gr.to_process || data.process || "?") + "</div>");
      lines.push('</div>');
    }

    if (data.process) {
      lines.push('<div class="trace-section"><div class="trace-section__head">Process</div>');
      lines.push('<div class="trace-row">' + escapeHtml(data.process) + '</div>');
      lines.push('</div>');
    }

    const graph = data.graph || data.execution_plan || [];
    if (graph.length) {
      lines.push('<div class="trace-section"><div class="trace-section__head">Execution plan</div>');
      graph.forEach(function (node) {
        const dep = node.depends_on || node.from || "—";
        const cond = node.condition ? " · " + escapeHtml(node.condition) : "";
        const def  = node.deferred ? ' <span class="status-retrying">[deferred]</span>' : "";
        lines.push('<div class="trace-row">' +
                   escapeHtml(node.block || node.to || "?") + " ← " +
                   escapeHtml(dep) + cond + def + '</div>');
      });
      lines.push('</div>');
    }

    if (Array.isArray(data.warnings) && data.warnings.length) {
      lines.push('<div class="trace-section"><div class="trace-section__head">Warnings</div>');
      data.warnings.forEach(function (w) {
        lines.push('<div class="trace-row status-retrying">' + escapeHtml(w) + '</div>');
      });
      lines.push('</div>');
    }

    return lines.join("");
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  async function hydrateBody(ws) {
    try {
      const res = await fetch(ws.contentUrl || urlFor(ws.type, ws.resourceId));
      const html = await res.text();
      ws.bodyHtml = html;
      const el = document.getElementById(ws.id);
      if (el) {
        const body = el.querySelector(".window__body");
        if (body) body.innerHTML = html;
      }
    } catch (e) {
      const el = document.getElementById(ws.id);
      if (el) {
        const body = el.querySelector(".window__body");
        if (body) body.innerHTML = '<div class="window-error">failed to load</div>';
      }
    }
  }
})();

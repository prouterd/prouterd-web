// ws_client.js
//
// Persistent WebSocket connection to the daemon's /v1/events endpoint.
// Carries three concerns over the same socket:
//
//   1. Topic pub/sub for live updates — subscribe(topic, cb) /
//      unsubscribe(topic, cb). Server pushes
//      `{ topic, type, payload }` frames; we fan out to per-topic listeners.
//
//   2. RPC — call(method, args) → Promise. Sends
//      `{ id, type: "call", payload: { method, args } }` and resolves on
//      `{ reply_to: id, type: "reply", payload }` or rejects on
//      `{ reply_to: id, type: "error", payload: { code, message } }`.
//      Replaces all the HTTP /v1/* fetches the SPA used to do — the
//      daemon's HTTP API stays as-is for non-browser clients (curl /
//      automation), but the console talks WS-only.
//
//   3. CLI is NOT here — assets/cli_session.js opens a dedicated WS per
//      CLI window to /v1/cli/:session_id so command streams don't share
//      the events bus.
//
// Auto-reconnects with exponential backoff. On reconnect, re-subscribes
// every active topic. In-flight calls during a disconnect are rejected
// (they won't see a reply); the caller decides whether to retry.

(function () {
  "use strict";

  const RECONNECT_INITIAL_MS = 500;
  const RECONNECT_MAX_MS     = 30000;
  const PING_INTERVAL_MS     = 25000;
  const DEFAULT_CALL_TIMEOUT = 30000;

  const state = {
    ws: null,
    connState: "connecting",
    listeners:    new Map(),    // topic → Set<callback>
    activeTopics: new Set(),    // topics we've asked the server to subscribe us to
    pendingCalls: new Map(),    // msgId → { resolve, reject, timer }
    queuedCalls:  [],           // [{ id, frame, handler }] — waiting for ws open
    reconnectMs:    RECONNECT_INITIAL_MS,
    reconnectTimer: null,
    pingTimer:      null,
    nextMsgId:  1,
    statusEl:   null,
    redirectingForAuth: false
  };

  window.ProuterdWS = {
    subscribe:   subscribe,
    unsubscribe: unsubscribe,
    call:        call,
    state:       state,
    isOpen:      function () { return state.connState === "open"; }
  };

  document.addEventListener("DOMContentLoaded", function () {
    state.statusEl = document.querySelector(".top-bar__health");
    connect();
  });

  // ----- connection lifecycle -----

  function connect() {
    setStatus("connecting");
    if (typeof window.ProuterdCore === "undefined" ||
        typeof window.ProuterdCore.wsUrl !== "function") {
      scheduleReconnect();
      return;
    }

    let url;
    try { url = window.ProuterdCore.wsUrl("/v1/events"); }
    catch (e) { scheduleReconnect(); return; }

    let ws;
    try { ws = new WebSocket(url); }
    catch (e) { scheduleReconnect(); return; }

    state.ws = ws;

    ws.addEventListener("open", function () {
      state.reconnectMs = RECONNECT_INITIAL_MS;
      setStatus("open");

      state.activeTopics.forEach(function (topic) {
        sendRaw({ id: nextId(), type: "subscribe", payload: { topic: topic } });
      });

      flushQueuedCalls();

      state.pingTimer = setInterval(function () {
        sendRaw({ id: nextId(), type: "ping" });
      }, PING_INTERVAL_MS);
    });

    ws.addEventListener("message", function (e) {
      let msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      dispatch(msg);
    });

    ws.addEventListener("close", function () {
      if (state.pingTimer) { clearInterval(state.pingTimer); state.pingTimer = null; }
      state.ws = null;
      setStatus("closed");
      rejectAllInFlight("WebSocket closed");
      scheduleReconnect();
    });

    ws.addEventListener("error", function () { /* close will follow */ });
  }

  function scheduleReconnect() {
    if (state.reconnectTimer) return;
    state.reconnectTimer = setTimeout(function () {
      state.reconnectTimer = null;
      state.reconnectMs    = Math.min(state.reconnectMs * 2, RECONNECT_MAX_MS);
      connect();
    }, state.reconnectMs);
  }

  // ----- top-bar status pill -----

  function setStatus(s) {
    state.connState = s;
    if (!state.statusEl) return;

    if (s === "open") {
      state.statusEl.textContent = "● live";
      state.statusEl.className = "top-bar__health top-bar__health--ok";
    } else if (s === "connecting") {
      state.statusEl.textContent = "● connecting";
      state.statusEl.className = "top-bar__health top-bar__health--warn";
    } else {
      state.statusEl.textContent = "● disconnected";
      state.statusEl.className = "top-bar__health top-bar__health--fail";
    }
  }

  // ----- frame I/O -----

  function nextId() { return "msg_" + (state.nextMsgId++); }

  function sendRaw(msg) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify(msg));
      return true;
    }
    return false;
  }

  function dispatch(msg) {
    if (msg.reply_to && state.pendingCalls.has(msg.reply_to)) {
      const h = state.pendingCalls.get(msg.reply_to);
      state.pendingCalls.delete(msg.reply_to);
      if (h.timer) clearTimeout(h.timer);
      if (msg.type === "reply") {
        h.resolve(msg.payload == null ? null : msg.payload);
      } else if (msg.type === "error") {
        const p = msg.payload || {};
        const err = new Error(p.message || "rpc error");
        err.code = p.code;
        err.payload = p;
        if (p.code === "unauthorized") redirectToLogin();
        h.reject(err);
      } else {
        h.reject(new Error("unexpected reply frame type: " + msg.type));
      }
      return;
    }

    const topic = msg.topic;
    if (!topic) return;  // pong / hello / unknown — no-op
    const listeners = state.listeners.get(topic);
    if (!listeners) return;
    listeners.forEach(function (cb) {
      try { cb(msg.payload || {}, topic); }
      catch (e) { /* swallow — one bad listener can't poison the bus */ }
    });
  }

  function rejectAllInFlight(reason) {
    state.pendingCalls.forEach(function (h) {
      if (h.timer) clearTimeout(h.timer);
      h.reject(new Error(reason));
    });
    state.pendingCalls.clear();
    state.queuedCalls.forEach(function (q) {
      if (q.handler.timer) clearTimeout(q.handler.timer);
      q.handler.reject(new Error(reason));
    });
    state.queuedCalls = [];
  }

  function flushQueuedCalls() {
    const pending = state.queuedCalls;
    state.queuedCalls = [];
    pending.forEach(function (q) {
      state.pendingCalls.set(q.id, q.handler);
      if (!sendRaw(q.frame)) {
        // Lost the open between flushQueuedCalls and sendRaw — re-queue.
        state.pendingCalls.delete(q.id);
        state.queuedCalls.push(q);
      }
    });
  }

  function redirectToLogin() {
    if (state.redirectingForAuth) return;
    state.redirectingForAuth = true;
    if (window.ProuterdCore && typeof window.ProuterdCore.logout === "function") {
      window.ProuterdCore.logout();
    }
  }

  // ----- public API -----

  function subscribe(topic, cb) {
    if (!state.listeners.has(topic)) state.listeners.set(topic, new Set());
    state.listeners.get(topic).add(cb);

    if (!state.activeTopics.has(topic)) {
      state.activeTopics.add(topic);
      sendRaw({ id: nextId(), type: "subscribe", payload: { topic: topic } });
    }

    return function () { unsubscribe(topic, cb); };
  }

  function unsubscribe(topic, cb) {
    const listeners = state.listeners.get(topic);
    if (!listeners) return;
    listeners.delete(cb);
    if (listeners.size === 0) {
      state.listeners.delete(topic);
      state.activeTopics.delete(topic);
      sendRaw({ id: nextId(), type: "unsubscribe", payload: { topic: topic } });
    }
  }

  function call(method, args, opts) {
    opts = opts || {};
    const timeoutMs = opts.timeoutMs == null ? DEFAULT_CALL_TIMEOUT : opts.timeoutMs;

    return new Promise(function (resolve, reject) {
      const id = nextId();
      const handler = { resolve: resolve, reject: reject, timer: null };
      if (timeoutMs > 0) {
        handler.timer = setTimeout(function () {
          state.pendingCalls.delete(id);
          // Also drop from queue if still waiting there.
          state.queuedCalls = state.queuedCalls.filter(function (q) { return q.id !== id; });
          reject(new Error("call timeout: " + method));
        }, timeoutMs);
      }
      const frame = { id: id, type: "call", payload: { method: method, args: args || {} } };

      if (state.connState === "open" && state.ws && state.ws.readyState === WebSocket.OPEN) {
        state.pendingCalls.set(id, handler);
        if (!sendRaw(frame)) {
          state.pendingCalls.delete(id);
          if (handler.timer) clearTimeout(handler.timer);
          reject(new Error("send failed"));
        }
      } else {
        state.queuedCalls.push({ id: id, frame: frame, handler: handler });
      }
    });
  }
})();

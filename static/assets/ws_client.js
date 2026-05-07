// ws_client.js — Phase UI-6.
//
// Persistent WebSocket connection to /ws.
// - Connects on page load; auto-reconnects with exponential backoff.
// - Resubscribes all topics after a successful reconnect so window
//   listeners survive transient disconnects without re-registering.
// - Dispatches incoming events to per-topic listeners registered via
//   ProuterdWS.subscribe(topic, cb).
// - Mirrors connection state into the top-bar health pill so the
//   operator sees connecting / open / disconnected at a glance.
//
// Server protocol: spec §14, with the small extension that server-emitted
// events carry an explicit `topic` field at the top level so the client
// can dispatch deterministically.

(function () {
  "use strict";

  const RECONNECT_INITIAL_MS = 500;
  const RECONNECT_MAX_MS     = 30000;
  const PING_INTERVAL_MS     = 25000;

  const state = {
    ws: null,
    connState: "connecting",
    listeners:     new Map(),   // topic → Set<callback>
    activeTopics:  new Set(),   // topics we have asked the server to subscribe us to
    replyHandlers: new Map(),   // outgoing msg id → { onChunk, onComplete, onError }
    reconnectMs: RECONNECT_INITIAL_MS,
    reconnectTimer: null,
    pingTimer: null,
    nextMsgId: 1,
    statusEl: null
  };

  window.ProuterdWS = {
    subscribe,
    unsubscribe,
    runCommand,
    state,
    isOpen: function () { return state.connState === "open"; }
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

      // Resubscribe everything we currently have listeners for.
      state.activeTopics.forEach(function (topic) {
        sendRaw({ id: nextId(), type: "subscribe", payload: { topic: topic } });
      });

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
    // Replies to a request go to that request's per-msg-id handler set.
    if (msg.reply_to && state.replyHandlers.has(msg.reply_to)) {
      const h = state.replyHandlers.get(msg.reply_to);
      if (msg.type === "command.output") {
        if (h.onChunk) h.onChunk(msg.payload || {});
      } else if (msg.type === "command.complete") {
        if (h.onComplete) h.onComplete(msg.payload || {});
        state.replyHandlers.delete(msg.reply_to);
      } else if (msg.type === "error") {
        if (h.onError) h.onError(msg.payload || {});
        state.replyHandlers.delete(msg.reply_to);
      }
      return;
    }

    const topic = msg.topic;
    if (!topic) return;  // unsolicited replies / pong / hello: nothing to do
    const listeners = state.listeners.get(topic);
    if (!listeners) return;
    listeners.forEach(function (cb) {
      try { cb(msg.payload || {}, topic); }
      catch (e) { /* swallow — one bad listener can't poison the bus */ }
    });
  }

  function runCommand(command, sessionId, handlers) {
    const id = nextId();
    state.replyHandlers.set(id, handlers || {});
    const ok = sendRaw({
      id: id,
      type: "command.exec",
      payload: { command: command, session_id: sessionId }
    });
    if (!ok) {
      state.replyHandlers.delete(id);
      if (handlers && handlers.onError) {
        handlers.onError({ code: "ws_closed", message: "WebSocket not connected" });
      }
    }
    return id;
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
})();

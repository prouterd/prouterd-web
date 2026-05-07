// cli_session.js
//
// Per-session persistent WS to the daemon's /v1/cli/:session_id. One
// connection per CLI window, reused across commands. Mirrors the frame
// protocol of the old Ruby CliBridge:
//   send: { id: "c1", type: "command.exec", payload: { command } }
//   recv: command.output { chunk, stream }
//         command.complete { exit_code, prompt }
//         error { message }

(function () {
  "use strict";

  function open(sessionId) {
    if (!sessionId) throw new Error("cli session: sessionId required");
    if (typeof window.ProuterdCore === "undefined") throw new Error("ProuterdCore missing");

    const url = window.ProuterdCore.wsUrl("/v1/cli/" + encodeURIComponent(sessionId));

    const sess = {
      url: url,
      ws: null,
      open: false,
      pending: null,            // { handlers, command, sentId } in-flight
      queue: [],                // commands waiting for connect
      msgCounter: 0,
      send: send,
      close: close
    };
    connect(sess);
    return sess;
  }

  function connect(sess) {
    let ws;
    try { ws = new WebSocket(sess.url); }
    catch (e) { fail(sess, "ws construct failed: " + e.message); return; }

    sess.ws = ws;
    ws.addEventListener("open", function () {
      sess.open = true;
      flush(sess);
    });
    ws.addEventListener("message", function (e) {
      let msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      handle(sess, msg);
    });
    ws.addEventListener("close", function () {
      sess.open = false;
      sess.ws = null;
      if (sess.pending && sess.pending.handlers && sess.pending.handlers.onError) {
        sess.pending.handlers.onError({ code: "ws_closed", message: "CLI WebSocket closed" });
      }
      sess.pending = null;
    });
    ws.addEventListener("error", function () { /* close will follow */ });
  }

  function send(command, handlers) {
    const sess = this;
    if (sess.pending) {
      sess.queue.push({ command: command, handlers: handlers });
      return;
    }
    if (!sess.open || !sess.ws) {
      sess.queue.push({ command: command, handlers: handlers });
      return;
    }
    dispatch(sess, command, handlers);
  }

  function dispatch(sess, command, handlers) {
    sess.msgCounter++;
    const id = "c" + sess.msgCounter;
    sess.pending = { id: id, command: command, handlers: handlers || {} };
    try {
      sess.ws.send(JSON.stringify({
        id: id, type: "command.exec",
        payload: { command: command }
      }));
    } catch (e) {
      const h = sess.pending.handlers; sess.pending = null;
      if (h.onError) h.onError({ code: "send_failed", message: e.message });
      flush(sess);
    }
  }

  function flush(sess) {
    if (sess.pending) return;
    if (!sess.open || !sess.ws) return;
    if (sess.queue.length === 0) return;
    const next = sess.queue.shift();
    dispatch(sess, next.command, next.handlers);
  }

  function handle(sess, msg) {
    if (!sess.pending) return;
    const h = sess.pending.handlers;
    if (msg.type === "command.output") {
      if (h.onChunk) h.onChunk(msg.payload || {});
    } else if (msg.type === "command.complete") {
      sess.pending = null;
      if (h.onComplete) h.onComplete(msg.payload || {});
      flush(sess);
    } else if (msg.type === "error") {
      sess.pending = null;
      if (h.onError) h.onError(msg.payload || {});
      flush(sess);
    }
  }

  function close() {
    const sess = this;
    if (sess.ws) {
      try { sess.ws.close(); } catch (e) { /* ignore */ }
    }
    sess.ws = null;
    sess.open = false;
    sess.pending = null;
    sess.queue = [];
  }

  function fail(sess, msg) {
    sess.open = false;
    if (sess.pending && sess.pending.handlers && sess.pending.handlers.onError) {
      sess.pending.handlers.onError({ code: "open_failed", message: msg });
    }
    sess.pending = null;
  }

  window.ProuterdCli = { open: open };
})();

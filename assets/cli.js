// cli.js
//
// Wires up CLI windows: input + output area, command history (↑/↓)
// persisted in localStorage per session_id, and command dispatch via
// ProuterdCli.open(sessionId) — a dedicated WS to /v1/cli/:sid.
//
// CLI window markup (emitted by windows/cli.js renderer):
//
//   <div class="cli" data-cli-session="<sid>">
//     <div class="cli__output"></div>
//     <div class="cli__inputline">
//       <span class="cli__prompt">prouter# </span>
//       <input class="cli__input">
//     </div>
//   </div>
//
// We attach to each .cli element exactly once (idempotent via a marker
// data attribute) so re-hydration on live-update doesn't stack
// duplicate handlers.

(function () {
  "use strict";

  const HISTORY_LIMIT  = 200;
  const HISTORY_PREFIX = "prouterd.cli.history.";

  document.addEventListener("DOMContentLoaded", function () {
    const workspace = document.getElementById("workspace");
    if (!workspace) return;

    document.querySelectorAll(".cli").forEach(initCli);

    const observer = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (node) {
          if (node.nodeType !== 1) return;
          if (node.classList && node.classList.contains("cli")) initCli(node);
          if (node.querySelectorAll) node.querySelectorAll(".cli").forEach(initCli);
        });
      });
    });
    observer.observe(workspace, { childList: true, subtree: true });

    // Click anywhere inside a CLI window body → focus its input.
    workspace.addEventListener("click", function (e) {
      const cli = e.target.closest(".cli");
      if (!cli) return;
      if (e.target.matches(".cli__input")) return;
      const input = cli.querySelector(".cli__input");
      if (input) input.focus();
    });
  });

  function initCli(cli) {
    if (cli.dataset.cliInit === "1") return;
    cli.dataset.cliInit = "1";

    const output    = cli.querySelector(".cli__output");
    const input     = cli.querySelector(".cli__input");
    const promptEl  = cli.querySelector(".cli__prompt");
    const sessionId = cli.dataset.cliSession;
    if (!output || !input || !promptEl || !sessionId) return;

    const st = {
      sessionId:   sessionId,
      history:     loadHistory(sessionId),
      historyIdx:  -1,
      pendingDraft: "",
      session:     null
    };
    if (window.ProuterdCli && typeof window.ProuterdCli.open === "function") {
      try { st.session = window.ProuterdCli.open(sessionId); }
      catch (e) { /* will surface as "session not connected" on first command */ }
    }

    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter") {
        e.preventDefault();
        const line = input.value;
        input.value = "";
        sendCommand(st, line, output, promptEl, input);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        if (st.history.length === 0) return;
        if (st.historyIdx === -1) {
          st.pendingDraft = input.value;
          st.historyIdx = st.history.length - 1;
        } else if (st.historyIdx > 0) {
          st.historyIdx -= 1;
        }
        input.value = st.history[st.historyIdx];
        moveCursorToEnd(input);
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        if (st.historyIdx === -1) return;
        if (st.historyIdx < st.history.length - 1) {
          st.historyIdx += 1;
          input.value = st.history[st.historyIdx];
        } else {
          st.historyIdx = -1;
          input.value = st.pendingDraft;
          st.pendingDraft = "";
        }
        moveCursorToEnd(input);
      }
    });

    setTimeout(function () { input.focus(); }, 0);
  }

  function sendCommand(st, line, output, promptEl, input) {
    appendLine(output, promptEl.textContent + line, "cli__line cli__line--echo");

    const trimmed = line.trim();
    if (trimmed === "") return;

    if (st.history[st.history.length - 1] !== trimmed) {
      st.history.push(trimmed);
      while (st.history.length > HISTORY_LIMIT) st.history.shift();
      saveHistory(st.sessionId, st.history);
    }
    st.historyIdx = -1;
    st.pendingDraft = "";

    if (!st.session) {
      appendLine(output, "(CLI session not connected)", "cli__line cli__line--error");
      return;
    }

    input.disabled = true;

    st.session.send(trimmed, {
      onChunk: function (payload) {
        appendChunk(output, payload.chunk || "", payload.stream || "stdout");
      },
      onComplete: function (payload) {
        if (payload && typeof payload.prompt === "string") {
          promptEl.textContent = payload.prompt;
        }
        if (payload && typeof payload.exit_code === "number" && payload.exit_code !== 0) {
          appendLine(output, "[exit " + payload.exit_code + "]", "cli__line cli__line--exitcode");
        }
        input.disabled = false;
        input.focus();
      },
      onError: function (payload) {
        const msg = (payload && payload.message) || "command failed";
        appendLine(output, "% " + msg, "cli__line cli__line--error");
        input.disabled = false;
        input.focus();
      }
    });
  }

  function appendLine(output, text, klass) {
    const div = document.createElement("div");
    div.className = klass;
    div.textContent = text;
    output.appendChild(div);
    output.scrollTop = output.scrollHeight;
  }

  function appendChunk(output, chunk, stream) {
    const div = document.createElement("div");
    div.className = "cli__line cli__line--" + stream;
    div.textContent = String(chunk).replace(/\r?\n+$/, "");
    output.appendChild(div);
    output.scrollTop = output.scrollHeight;
  }

  function moveCursorToEnd(input) {
    const n = input.value.length;
    try { input.setSelectionRange(n, n); } catch (e) { /* ignore */ }
  }

  function loadHistory(sessionId) {
    try {
      const raw = localStorage.getItem(HISTORY_PREFIX + sessionId);
      if (!raw) return [];
      return JSON.parse(raw) || [];
    } catch (e) { return []; }
  }

  function saveHistory(sessionId, history) {
    try {
      localStorage.setItem(HISTORY_PREFIX + sessionId, JSON.stringify(history));
    } catch (e) { /* quota — best effort */ }
  }
})();

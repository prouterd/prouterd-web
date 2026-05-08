(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("logs", async function (resource) {
    if (!resource) return runPicker("logs", await A.listRuns({ limit: 30 }));
    const m = String(resource).split("/");
    const runUid = m[0], stepId = m[1] || null;
    const logs = await A.getStepLogs(runUid, stepId ? { step_id: stepId } : {});

    const streams = Array.from(new Set(logs.map(function (l) { return l.stream; }))).sort().join(", ");
    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Logs: ' + esc(runUid) + (stepId ? " · step " + esc(stepId) : "") + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>entries</b> <span data-logs-count>' + esc(logs.length) + '</span></span>'
      +     '<span><b>streams</b> <span data-logs-streams>' + esc(streams) + '</span></span>'
      +     '<span><a href="#" data-open-window="run" data-open-resource="' + esc(runUid) + '">open run inspector</a></span>'
      +   '</div>'
      + '</header>'
      + renderLogsBody(logs, !!stepId);
  });

  // Incremental tail. log.appended events on the logs:<uid> topic
  // already carry the full entry (run_uid, step_id, stream, content,
  // created_at) so we append a single line in place instead of
  // re-fetching the whole buffer. Falls back to debounced re-hydrate
  // when the body isn't ready (e.g. window opened mid-event), see
  // window_manager.js attachLiveSubscriptions.
  W.registerAppender("logs", function (ws, payload, topic) {
    if (!String(topic || "").startsWith("logs:")) return false;
    const el = document.getElementById(ws.id);
    if (!el) return false;
    const body = el.querySelector(".window__body");
    if (!body) return false;
    const container = body.querySelector(".logs");
    if (!container) return false;

    // Filter to this window's step, if any (resource is "<uid>" or
    // "<uid>/<step>").
    const m = String(ws.resourceId || "").split("/");
    const wantStep = m[1] != null && m[1] !== "" ? Number(m[1]) : null;
    if (wantStep != null && Number(payload.step_id) !== wantStep) return true;

    // Drop the empty-state placeholder on first real entry.
    const empty = container.querySelector(".logs__empty");
    if (empty) empty.remove();

    const stream = payload.stream || "stdout";
    const line = document.createElement("div");
    line.className = "logs__line logs__line--" + stream.replace(/[^A-Za-z0-9_-]/g, "");
    let html = '<span class="logs__ts">'      + esc(formatTs(payload.created_at)) + '</span>' +
               '<span class="logs__stream">'  + esc(stream) + '</span>';
    if (wantStep == null) {
      html += '<span class="logs__step">step ' +
        (payload.step_id == null ? "—" : esc(payload.step_id)) + '</span>';
    }
    html += '<span class="logs__content">' + esc(payload.content || "") + '</span>';
    line.innerHTML = html;
    container.appendChild(line);

    // Update the entries-count pill.
    const countEl = body.querySelector("[data-logs-count]");
    if (countEl) {
      const next = (parseInt(countEl.textContent, 10) || 0) + 1;
      countEl.textContent = String(next);
    }

    // Auto-scroll if the operator was already pinned to the bottom.
    const nearBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 60;
    if (nearBottom) body.scrollTop = body.scrollHeight;

    return true;
  });

  function renderLogsBody(logs, hideStep) {
    if (logs.length === 0) {
      return '<div class="logs"><div class="logs__empty">no log entries</div></div>';
    }
    let out = '<div class="logs">';
    logs.forEach(function (l) {
      out += '<div class="logs__line logs__line--' + esc(l.stream) + '">' +
        '<span class="logs__ts">'      + esc(formatTs(l.created_at)) + '</span>' +
        '<span class="logs__stream">'  + esc(l.stream) + '</span>' +
        (hideStep ? "" : '<span class="logs__step">step ' + (l.step_id == null ? "—" : esc(l.step_id)) + '</span>') +
        '<span class="logs__content">' + esc(l.content || "") + '</span>' +
        '</div>';
    });
    out += "</div>";
    return out;
  }

  function runPicker(kind, runs) {
    let out = ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">' + (kind === "logs" ? "Logs" : "Artifacts") + ' · pick a run</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>recent runs</b> ' + esc(runs.length) + '</span>'
      +     '<span class="window-placeholder__hint">click a row to open this run\'s ' + esc(kind) + ' window</span>'
      +   '</div>'
      + '</header>';
    if (runs.length === 0) {
      return out + '<table class="data-table"><tbody><tr><td class="data-table__empty">No runs yet.</td></tr></tbody></table>';
    }
    out += '<table class="data-table"><thead><tr>' +
      '<th>Run</th><th>Process</th><th>Status</th><th>Started</th><th>Duration</th>' +
      '</tr></thead><tbody>';
    runs.forEach(function (r) {
      out += '<tr class="data-table__row--clickable" data-open-window="' + esc(kind) + '" ' +
             'data-open-resource="' + esc(r.run_uid) + '">' +
        "<td>" + esc(r.run_uid) + "</td>" +
        "<td>" + esc(r.process_name) + "</td>" +
        '<td class="status-' + esc(r.status) + '">' + esc(r.status) + '</td>' +
        "<td>" + (r.started_at == null ? "—" : esc(r.started_at)) + "</td>" +
        "<td>" + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  }

  function formatTs(ts) {
    if (ts == null) return "";
    try { return new Date(ts).toISOString().slice(11, 23); }
    catch (e) { return String(ts); }
  }
})();

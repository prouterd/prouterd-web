(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("run", async function (uid) {
    const r = await A.getRun(uid);
    if (!r) return '<div class="window-error">run ' + esc(uid) + ' not found</div>';
    const steps = await A.getRunSteps(uid);

    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Run: ' + esc(r.run_uid) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>process</b> <a href="#" data-open-window="process" data-open-resource="' + esc(r.process_name) + '">' + esc(r.process_name) + '</a></span>'
      +     '<span><b>status</b> <span class="status-' + esc(r.status) + '">' + esc(r.status) + '</span></span>'
      +     '<span><b>started</b> ' + (r.started_at == null ? "—" : esc(r.started_at)) + '</span>'
      +     '<span><b>duration</b> ' + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + '</span>'
      +     '<span><b>config</b> #' + (r.config_commit == null ? "—" : esc(r.config_commit)) + '</span>'
      +     '<span><b>trigger</b> ' + (r.trigger == null ? "—" : esc(r.trigger)) + '</span>'
      +     (r.thread_id ? '<span><b>thread</b> ' + esc(r.thread_id) + '</span>' : "")
      +     ((r.tokens_in || r.tokens_out) ? '<span><b>tokens</b> ' + esc(r.tokens_in) + ' ↑ / ' + esc(r.tokens_out) + ' ↓</span>' : "")
      +     (r.replay_of ? '<span><b>replay of</b> <a href="#" data-open-window="run" data-open-resource="' + esc(r.replay_of) + '">' + esc(r.replay_of) + '</a></span>' : "")
      +   '</div>'
      +   (r.status === "paused" ? resumeAction(r.run_uid) : "")
      + '</header>'
      + '<nav class="tabs" role="tablist">'
      +   '<button type="button" class="tab tab--active" data-tab="summary">Summary</button>'
      +   '<button type="button" class="tab"             data-tab="steps">Steps</button>'
      + '</nav>'
      + '<div class="tab-panel" data-tab-panel="summary">'
      +   summaryTable(r)
      + '</div>'
      + '<div class="tab-panel" data-tab-panel="steps" hidden>'
      +   stepsTable(uid, steps)
      + '</div>';
  });

  function resumeAction(uid) {
    return '<div class="inspector-header__actions">' +
      '<button type="button" class="action__btn" data-run-action="resume" ' +
        'data-run-uid="' + esc(uid) + '">Resume run…</button>' +
      '</div>';
  }

  function summaryTable(r) {
    function row(k, v, raw) {
      const cell = v == null ? "—" : (raw ? v : esc(v));
      return "<tr><td>" + esc(k) + "</td><td>" + cell + "</td></tr>";
    }
    return '<table class="kv-table"><tbody>' +
      row("Run",           r.run_uid) +
      row("Process",       r.process_name) +
      row("Thread",        r.thread_id) +
      row("Status",        '<span class="status-' + esc(r.status) + '">' + esc(r.status) + '</span>', true) +
      row("Started",       r.started_at) +
      row("Finished",      r.finished_at) +
      row("Duration",      r.duration_ms == null ? null : r.duration_ms + " ms") +
      row("Tokens in",     r.tokens_in  ? esc(r.tokens_in)  : null, true) +
      row("Tokens out",    r.tokens_out ? esc(r.tokens_out) : null, true) +
      row("Config commit", r.config_commit == null ? null : "#" + r.config_commit) +
      row("Trigger",       r.trigger) +
      row("Interface",     r.interface_name) +
      row("Replayable",    r.replayable ? "yes" : "no") +
      (r.error_summary ? row("Error", '<span class="status-failed">' + esc(r.error_summary) + '</span>', true) : "") +
      "</tbody></table>";
  }

  function stepsTable(uid, steps) {
    if (!steps.length) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No steps yet.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Block</th><th>Status</th><th>Attempt</th><th>Image</th><th>Exit</th><th>Error</th><th>Duration</th><th>Started</th>' +
      '</tr></thead><tbody>';
    steps.forEach(function (s) {
      out += '<tr class="data-table__row--clickable" data-open-window="step" ' +
             'data-open-resource="' + esc(uid + "/" + s.id) + '">' +
        '<td>' + esc(s.block_name) + '</td>' +
        '<td class="status-' + esc(s.status) + '">' + esc(s.status) + '</td>' +
        '<td>' + esc(s.attempt) + '</td>' +
        '<td>' + (s.image == null ? "—" : esc(s.image)) + '</td>' +
        '<td>' + (s.exit_code == null ? "—" : esc(s.exit_code)) + '</td>' +
        '<td>' + (s.error_type == null ? "—" : esc(s.error_type)) + '</td>' +
        '<td>' + (s.duration_ms == null ? "—" : esc(s.duration_ms + " ms")) + '</td>' +
        '<td>' + (s.started_at == null ? "—" : esc(s.started_at)) + '</td>' +
        '</tr>';
    });
    out += "</tbody></table>";
    return out;
  }
})();

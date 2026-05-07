(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("runs", async function () {
    const runs = await A.listRuns({ limit: 50 });
    if (runs.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No runs.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Run</th><th>Process</th><th>Status</th><th>Started</th><th>Duration</th><th>Trigger</th>' +
      '</tr></thead><tbody>';
    runs.forEach(function (r) {
      out += '<tr class="data-table__row--clickable" data-open-window="run" ' +
             'data-open-resource="' + esc(r.run_uid) + '">' +
        '<td>' + esc(r.run_uid) + '</td>' +
        '<td>' + esc(r.process_name) + '</td>' +
        '<td class="status-' + esc(r.status) + '">' + esc(r.status) + '</td>' +
        '<td>' + (r.started_at == null ? "—" : esc(r.started_at)) + '</td>' +
        '<td>' + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + '</td>' +
        '<td>' + (r.trigger == null ? "—" : esc(r.trigger)) + '</td>' +
        '</tr>';
    });
    out += "</tbody></table>";
    return out;
  });
})();

(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("processes", async function () {
    const procs = await A.listProcesses();
    if (procs.length === 0) {
      return '<table class="data-table"><tbody>' +
        '<tr><td class="data-table__empty">No processes configured.</td></tr>' +
        '</tbody></table>';
    }
    let out = '<table class="data-table">' +
      '<thead><tr>' +
        '<th>Name</th><th>Status</th><th>Blocks</th><th>Routes</th>' +
        '<th>Queue</th><th>Last status</th>' +
      '</tr></thead><tbody>';
    procs.forEach(function (p) {
      out += '<tr class="data-table__row--clickable" data-open-window="process" ' +
             'data-open-resource="' + esc(p.name) + '">' +
        '<td>' + esc(p.name) + '</td>' +
        '<td class="status-' + esc(p.status) + '">' + esc(p.status) + '</td>' +
        '<td>' + esc(p.blocks) + '</td>' +
        '<td>' + esc(p.routes) + '</td>' +
        '<td>' + (p.queue == null ? "—" : esc(p.queue)) + '</td>' +
        '<td class="status-' + esc(p.last_status) + '">' + (p.last_status == null ? "—" : esc(p.last_status)) + '</td>' +
        '</tr>';
    });
    out += '</tbody></table>';
    return out;
  });
})();

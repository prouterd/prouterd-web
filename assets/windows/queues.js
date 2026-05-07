(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("queues", async function () {
    const qs = await A.listQueues();
    if (qs.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No queues defined.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Concurrency</th><th>Timeout</th>' +
      '</tr></thead><tbody>';
    qs.forEach(function (q) {
      out += "<tr>" +
        td(q.name) + td(q.concurrency) +
        td(q.timeout_ms == null ? null : q.timeout_ms + " ms") +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

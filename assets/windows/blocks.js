(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("blocks", async function () {
    const blocks = await A.listBlocks();
    if (blocks.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No blocks defined.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Block</th><th>Process</th><th>Interface</th><th>Call</th><th>Tags</th><th>Timeout</th><th>Retry</th>' +
      '</tr></thead><tbody>';
    blocks.forEach(function (b) {
      out += '<tr class="data-table__row--clickable" data-open-window="process" ' +
             'data-open-resource="' + esc(b.process) + '">' +
        td(b.name) + td(b.process) + td(W.blockKindLabel(b)) +
        '<td class="data-table__truncate">' + (b.call_summary == null ? "—" : esc(b.call_summary)) + "</td>" +
        '<td>' + W.blockBadges(b) + '</td>' +
        td(b.timeout_ms == null ? null : b.timeout_ms + " ms") +
        td(b.retry_policy) +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

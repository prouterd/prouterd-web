(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("interfaces", async function () {
    const ifs = await A.listInterfaces();
    if (ifs.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No interfaces configured.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Type</th><th>Direction</th><th>Config</th><th>Status</th>' +
      '</tr></thead><tbody>';
    ifs.forEach(function (i) {
      const fields = i.fields || {};
      const cfg = Object.keys(fields).length === 0 ? "—" :
        Object.keys(fields).map(function (k) { return esc(k) + "=" + esc(fields[k]); }).join("  ");
      out += "<tr>" +
        td(i.name) + td(i.kind) + td(i.direction) +
        '<td class="data-table__truncate">' + cfg + "</td>" +
        '<td class="status-' + esc(i.status) + '">' + esc(i.status) + '</td>' +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("routes", async function () {
    const routes = await A.listRoutes();
    if (routes.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No routes configured.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>From</th><th>To</th><th>Condition</th><th>On failure</th><th>Enabled</th>' +
      '</tr></thead><tbody>';
    routes.forEach(function (r) {
      out += "<tr>" +
        td(r.from) + td(r.to) + td(r.condition) + td(r.on_failure) +
        "<td>" + (r.enabled ? "yes" : "no") + "</td></tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

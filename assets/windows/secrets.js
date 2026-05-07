(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("secrets", async function () {
    const secrets = await A.listSecrets();
    let out;
    if (secrets.length === 0) {
      out = '<table class="data-table"><tbody><tr><td class="data-table__empty">No secrets declared.</td></tr></tbody></table>';
    } else {
      out = '<table class="data-table"><thead><tr>' +
        '<th>Name</th><th>Source type</th><th>Source ref</th><th>Used by</th><th>Status</th>' +
        '</tr></thead><tbody>';
      secrets.forEach(function (s) {
        const usedBy = (s.used_by && s.used_by.length) ? s.used_by.join(", ") : null;
        out += "<tr>" +
          td(s.name) + td(s.source_type) + td(s.source_ref) + td(usedBy) +
          '<td class="status-' + esc(s.status) + '">' + esc(s.status) + '</td>' +
          "</tr>";
      });
      out += "</tbody></table>";
    }
    out += '<p class="window-placeholder__hint" style="padding: 8px 12px; margin: 0;">' +
      "Secret values are never displayed — only their declared source reference." +
      '</p>';
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

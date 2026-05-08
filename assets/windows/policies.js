(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("policies", async function () {
    const policies = await A.listPolicies();
    if (policies.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No retry policies defined.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Attempts</th><th>Backoff</th><th>Initial delay</th>' +
      '<th>Max delay</th><th>Retry when</th><th>Stop on</th><th>Feedback</th><th>Timeout</th>' +
      '</tr></thead><tbody>';
    policies.forEach(function (p) {
      const fmtMatches = function (arr) {
        return (arr || []).map(function (m) {
          const vals = (m.values || []).map(function (v) {
            return typeof v === "string" ? '"' + v + '"' : String(v);
          }).join(",");
          return [m.path, m.operator, vals].filter(Boolean).join(" ").trim();
        }).join("  •  ");
      };
      const rw = fmtMatches(p.retry_when);
      const ro = fmtMatches(p.retry_stop);
      const fb = (p.retry_feedback || []).map(function (f) {
        return f.from + " → previous." + f.into;
      }).join("  •  ");
      out += "<tr>" +
        td(p.name) + td(p.retry_attempts) + td(p.retry_backoff) +
        td(p.retry_initial_delay_ms == null ? null : p.retry_initial_delay_ms + " ms") +
        td(p.retry_max_delay_ms == null ? null : p.retry_max_delay_ms + " ms") +
        '<td class="data-table__truncate">' + (rw === "" ? "—" : esc(rw)) + "</td>" +
        '<td class="data-table__truncate">' + (ro === "" ? "—" : esc(ro)) + "</td>" +
        '<td class="data-table__truncate">' + (fb === "" ? "—" : esc(fb)) + "</td>" +
        td(p.timeout_ms == null ? null : p.timeout_ms + " ms") +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

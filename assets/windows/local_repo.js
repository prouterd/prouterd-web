(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // Auto-pull state per `interface local_repo` whitelist entry.
  // Daemon polls each repo on its declared cadence; we surface the
  // most recent outcome so the operator can spot a stuck pull
  // (auth failure, missing remote, etc.) without tailing logs.
  W.register("local-repo", async function () {
    const entries = await A.getLocalRepoStatus();
    if (entries.length === 0) {
      return '<table class="data-table"><tbody><tr>' +
        '<td class="data-table__empty">' +
        'No local-repo auto-pull state — either no <code>interface local_repo</code> ' +
        'declares <code>auto-pull</code>, or the daemon just started and ' +
        'hasn\'t polled yet.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Interface</th><th>Repo</th><th>Status</th><th>Detail</th><th>Checked at</th>' +
      '</tr></thead><tbody>';
    entries.forEach(function (e) {
      const cls = e.ok ? "status-success" : "status-failed";
      const verdict = e.ok ? "ok" : "FAIL";
      const detail = e.ok ? (e.summary || "—")
                          : (e.error   || "(error not reported)");
      out += "<tr>" +
        "<td>" + (e.iface == null ? "—" : esc(e.iface)) + "</td>" +
        "<td>" + esc(e.repo) + "</td>" +
        '<td class="' + cls + '">' + esc(verdict) + "</td>" +
        '<td class="data-table__truncate">' + esc(detail) + "</td>" +
        "<td>" + (e.checked_at == null ? "—" : esc(e.checked_at)) + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });
})();

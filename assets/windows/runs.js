(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  const DEFAULT_LIMIT = 20;

  // resource is a query string: "limit=20&offset=40&process=foo".
  // null/undefined → first page, default limit, no filter.
  W.register("runs", async function (resource) {
    const params = parseParams(resource);

    const [runs, total] = await Promise.all([
      A.listRuns(params),
      A.countRuns(params)
    ]);
    const limit  = params.limit;
    const offset = params.offset;
    const filter = params.process_name || null;

    let out = '<table class="data-table">' +
      '<thead><tr>' +
        '<th>Run</th><th>Process</th><th>Status</th>' +
        '<th>Duration</th><th>Started</th><th>Trigger</th>' +
      '</tr></thead><tbody>';
    if (runs.length === 0) {
      out += '<tr><td colspan="6" class="data-table__empty">No runs yet.</td></tr>';
    } else {
      runs.forEach(function (r) {
        out += '<tr class="data-table__row--clickable" data-open-window="run" ' +
               'data-open-resource="' + esc(r.run_uid) + '">' +
          "<td>" + esc(r.run_uid) + "</td>" +
          "<td>" + esc(r.process_name) + "</td>" +
          '<td class="status-' + esc(r.status) + '">' + esc(r.status) + '</td>' +
          "<td>" + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + "</td>" +
          "<td>" + (r.started_at  == null ? "—" : esc(r.started_at)) + "</td>" +
          "<td>" + (r.trigger     == null ? "—" : esc(r.trigger)) + "</td>" +
          "</tr>";
      });
    }
    out += "</tbody></table>";

    const prevOffset = Math.max(offset - limit, 0);
    const nextOffset = offset + limit;
    let lastOffset   = Math.floor((total - 1) / limit) * limit;
    if (lastOffset < 0) lastOffset = 0;
    const shownFrom = runs.length === 0 ? 0 : offset + 1;
    const shownTo   = offset + runs.length;

    out += '<footer class="pagination">' +
      '<span class="pagination__info">' +
        (total === 0 ? "0 runs" :
          "runs " + shownFrom + "–" + shownTo + " of " + total +
          (filter ? " · process: " + esc(filter) : "")) +
      '</span>' +
      '<span class="pagination__buttons">' +
        pageBtn("first", offset === 0,             buildResource(filter, limit, 0)) +
        pageBtn("prev",  offset === 0,             buildResource(filter, limit, prevOffset)) +
        pageBtn("next",  nextOffset >= total,      buildResource(filter, limit, nextOffset)) +
        pageBtn("last",  offset >= lastOffset,     buildResource(filter, limit, lastOffset)) +
      '</span>' +
      '</footer>';
    return out;
  });

  function pageBtn(label, disabled, resource) {
    return '<button type="button" class="pagination__btn" ' +
      (disabled ? "disabled " : "") +
      'data-runs-page="' + esc(resource) + '">' + label + '</button>';
  }

  function parseParams(resource) {
    const out = { limit: DEFAULT_LIMIT, offset: 0 };
    if (!resource) return out;
    const sp = new URLSearchParams(resource);
    const lim = parseInt(sp.get("limit"),  10); if (!isNaN(lim) && lim > 0) out.limit  = lim;
    const off = parseInt(sp.get("offset"), 10); if (!isNaN(off) && off >= 0) out.offset = off;
    const proc = sp.get("process"); if (proc) out.process_name = proc;
    return out;
  }

  function buildResource(filter, limit, offset) {
    const sp = new URLSearchParams();
    sp.set("limit", String(limit));
    sp.set("offset", String(offset));
    if (filter) sp.set("process", filter);
    return sp.toString();
  }
})();

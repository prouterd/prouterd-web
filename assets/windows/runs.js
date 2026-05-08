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
    const filter = {
      process:   params.process_name || null,
      thread_id: params.thread_id    || null
    };

    let out = '<table class="data-table">' +
      '<thead><tr>' +
        '<th>Run</th><th>Process</th><th>Thread</th><th>Status</th>' +
        '<th>Duration</th><th>Tokens</th><th>Cost</th><th>Started</th><th>Trigger</th>' +
      '</tr></thead><tbody>';
    if (runs.length === 0) {
      out += '<tr><td colspan="9" class="data-table__empty">No runs yet.</td></tr>';
    } else {
      runs.forEach(function (r) {
        const tokens = (r.tokens_in || r.tokens_out)
          ? (r.tokens_in + " ↑ / " + r.tokens_out + " ↓") : "—";
        const cost = r.cost_usd > 0 ? "$" + r.cost_usd.toFixed(4) : "—";
        // Queued runs haven't started yet — fall back to created_at and
        // mark it visually so the operator can tell it's a "queued at"
        // timestamp, not a "started at" one.
        const when = r.started_at != null
          ? esc(r.started_at)
          : (r.created_at != null
              ? '<span class="status-queued">queued ' + esc(r.created_at) + '</span>'
              : "—");
        out += '<tr class="data-table__row--clickable" data-open-window="run" ' +
               'data-open-resource="' + esc(r.run_uid) + '">' +
          "<td>" + esc(r.run_uid) + "</td>" +
          "<td>" + esc(r.process_name) + "</td>" +
          "<td>" + (r.thread_id == null ? "—" : esc(r.thread_id)) + "</td>" +
          '<td class="status-' + esc(r.status) + '">' + esc(r.status) + '</td>' +
          "<td>" + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + "</td>" +
          "<td>" + esc(tokens) + "</td>" +
          "<td>" + esc(cost) + "</td>" +
          "<td>" + when + "</td>" +
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

    const filterLabel = [
      filter.process   ? "process: " + esc(filter.process)   : null,
      filter.thread_id ? "thread: "  + esc(filter.thread_id) : null
    ].filter(Boolean).join(" · ");
    out += '<footer class="pagination">' +
      '<span class="pagination__info">' +
        (total === 0 ? "0 runs" :
          "runs " + shownFrom + "–" + shownTo + " of " + total +
          (filterLabel ? " · " + filterLabel : "")) +
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
    const tid  = sp.get("thread_id"); if (tid) out.thread_id = tid;
    return out;
  }

  function buildResource(filter, limit, offset) {
    const sp = new URLSearchParams();
    sp.set("limit", String(limit));
    sp.set("offset", String(offset));
    if (filter && filter.process) sp.set("process", filter.process);
    if (filter && filter.thread_id) sp.set("thread_id", filter.thread_id);
    return sp.toString();
  }
})();

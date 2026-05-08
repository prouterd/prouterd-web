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
        td(b.name) + td(b.process) + td(blockKindLabel(b)) +
        '<td class="data-table__truncate">' + (b.call_summary == null ? "—" : esc(b.call_summary)) + "</td>" +
        '<td>' + tagBadges(b) + '</td>' +
        td(b.timeout_ms == null ? null : b.timeout_ms + " ms") +
        td(b.retry_policy) +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function blockKindLabel(b) {
    if (b.pause_reason) return "pause";
    if (b.barrier)     return "parallel barrier";
    return b.interface_label;
  }

  function tagBadges(b) {
    const tags = [];
    if (b.pause_reason)            tags.push(badge("pause",      "warn",  b.pause_reason));
    if (b.barrier)                 tags.push(badge("barrier",    "info",  b.barrier.join_strategy));
    if (b.skip_when)               tags.push(badge("skip-when",  "muted", null));
    if (b.fan_out)                 tags.push(badge("fan-out",    "info",  fanOutHint(b.fan_out)));
    if (b.agentic)                 tags.push(badge("agentic",    "accent", agenticHint(b.agentic)));
    if (b.vars && Object.keys(b.vars).length) tags.push(badge("vars", "muted", String(Object.keys(b.vars).length)));
    if (b.max_cost_usd != null)    tags.push(badge("$" + b.max_cost_usd.toFixed(2), "warn", "max-cost-usd cap"));
    return tags.length ? tags.join(" ") : "—";
  }

  function agenticHint(a) {
    const tools = (a.allowed_tools || []).length;
    return tools ? tools + " tool" + (tools === 1 ? "" : "s") : "no tools";
  }

  function fanOutHint(f) {
    const parts = ["→ " + f.into];
    if (f.maps && f.maps.length)         parts.push(f.maps.length + " maps");
    if (f.dedupe)                        parts.push("dedupe " + (f.dedupe.by || ""));
    if (f.rate_limit)                    parts.push("rate " + f.rate_limit.n + "/" + (f.rate_limit.window_ms || "") + "ms");
    return parts.join(" · ");
  }

  function badge(label, kind, hint) {
    const title = hint ? ' title="' + esc(String(hint)) + '"' : "";
    return '<span class="badge badge--' + esc(kind) + '"' + title + '>' + esc(label) + '</span>';
  }

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

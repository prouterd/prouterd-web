(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // `interface mcp <name>` declarations joined with live pool health.
  // Each row shows server kind/spec, current state, discovered tools,
  // and the last error (if any) — the standard Phase-39 MCP surface
  // exposed via /v1/mcp on core.
  W.register("mcp", async function () {
    const ifaces = await A.listMcp();
    if (ifaces.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No mcp interfaces declared.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Server</th><th>State</th><th>Tools</th>' +
      '<th>Cwd</th><th>Tool-call timeout</th><th>Last error</th>' +
      '</tr></thead><tbody>';
    ifaces.forEach(function (m) {
      const tools = (m.tools && m.tools.length)
        ? m.tools.map(function (t) { return esc(t.name || t); }).join(", ")
        : "—";
      out += "<tr>" +
        "<td>" + esc(m.name) + "</td>" +
        "<td>" + (m.server_label == null ? "—" : esc(m.server_label)) + "</td>" +
        '<td class="status-' + esc(stateClass(m.state)) + '">' + esc(m.state) + '</td>' +
        '<td class="data-table__truncate">' + tools + "</td>" +
        "<td>" + (m.cwd == null ? "—" : esc(m.cwd)) + "</td>" +
        "<td>" + (m.timeout_tool_call_ms == null ? "—" : esc(m.timeout_tool_call_ms + " ms")) + "</td>" +
        '<td class="data-table__truncate">' +
          (m.last_error == null ? "—" : '<span class="status-failed">' + esc(m.last_error) + '</span>') +
        "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  // Map MCP-pool states to the existing status-* color palette so the
  // colour coding is consistent with everything else in the console.
  function stateClass(state) {
    switch (state) {
      case "ready":    return "success";
      case "starting": return "running";
      case "degraded": return "retrying";
      case "stopped":  return "disabled";
      case "no_pool":  return "skipped";
      default:         return "queued";   // "unknown" et al.
    }
  }
})();

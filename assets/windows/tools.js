(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // Top-level `tool <name>` declarations. Used by agentic blocks.
  W.register("tools", async function () {
    const tools = await A.listTools();
    if (!tools.length) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No tools declared.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Args</th><th>Implementation</th><th>Description</th>' +
      '</tr></thead><tbody>';
    tools.forEach(function (t) {
      out += "<tr>" +
        td(t.name) +
        td((t.args || []).join(", ")) +
        td(t.impl_label) +
        '<td class="data-table__truncate">' + (t.description == null ? "—" : esc(t.description)) + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

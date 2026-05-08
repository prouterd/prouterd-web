(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // Top-level `prices <provider>` declarations. The cost-usd
  // accumulator multiplies these against per-attempt LLM token usage.
  W.register("prices", async function () {
    const tables = await A.listPrices();
    if (!tables.length) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No price tables declared. Add a <code>prices &lt;provider&gt;</code> block to enable cost_usd accumulation.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Provider</th><th>Model</th><th>Input ($/1M)</th><th>Output ($/1M)</th>' +
      '</tr></thead><tbody>';
    tables.forEach(function (t) {
      if (t.entries.length === 0) {
        out += "<tr>" + td(t.provider) + td(null) + td(null) + td(null) + "</tr>";
        return;
      }
      t.entries.forEach(function (e, idx) {
        out += "<tr>" +
          (idx === 0 ? '<td rowspan="' + t.entries.length + '">' + esc(t.provider) + "</td>" : "") +
          td(e.model) +
          td("$" + e.price_in.toFixed(4)) +
          td("$" + e.price_out.toFixed(4)) +
          "</tr>";
      });
    });
    out += "</tbody></table>";
    return out;
  });

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

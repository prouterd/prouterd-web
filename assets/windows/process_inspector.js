(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("process", async function (name) {
    const p = await A.getProcess(name);
    if (!p) {
      return '<div class="window-error">process ' + esc(name) + ' not found</div>';
    }

    const graphPayload = {
      nodes: p.blocks.map(function (b) {
        return {
          id: b.name, label: b.name, interface: b.interface_label,
          status: b.status, entry: b.name === p.entry_block,
          // Phase-37 markers for graph rendering.
          kind: b.pause_reason ? "pause" : (b.barrier ? "barrier" : "block"),
          agentic: !!b.agentic, fan_out: !!b.fan_out, skip_when: !!b.skip_when
        };
      }),
      edges: p.routes.map(function (r) {
        return {
          from: r.from, to: r.to, condition: r.condition,
          on_failure: !!r.on_failure, enabled: r.enabled
        };
      }),
      parallel_groups: (p.parallel_groups || [])
    };

    return ''
      // header
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Process: ' + esc(p.name) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>status</b> <span class="status-' + esc(p.status) + '">' + esc(p.status) + '</span></span>'
      +     '<span><b>queue</b> '       + (p.queue == null ? "—" : esc(p.queue)) + '</span>'
      +     '<span><b>entry</b> '       + (p.entry_block == null ? "—" : esc(p.entry_block)) + '</span>'
      +     '<span><b>blocks</b> '      + esc(p.blocks.length) + '</span>'
      +     '<span><b>routes</b> '      + esc(p.routes.length) + '</span>'
      +     (p.thread_id_template ? '<span><b>thread-id</b> <code>' + esc(p.thread_id_template) + '</code></span>' : "")
      +     ((p.parallel_groups || []).length ? '<span><b>parallel</b> ' + esc(p.parallel_groups.length) + '</span>' : "")
      +     '<span><b>last run</b> <span class="status-' + esc(p.last_status) + '">' + (p.last_status == null ? "—" : esc(p.last_status)) + '</span></span>'
      +   '</div>'
      + '</header>'
      // tabs
      + '<nav class="tabs" role="tablist">'
      +   '<button type="button" class="tab tab--active" data-tab="overview">Overview</button>'
      +   '<button type="button" class="tab"             data-tab="blocks">Blocks</button>'
      +   '<button type="button" class="tab"             data-tab="routes">Routes</button>'
      +   '<button type="button" class="tab"             data-tab="graph">Graph</button>'
      +   '<button type="button" class="tab"             data-tab="trigger">Trigger</button>'
      + '</nav>'
      // overview
      + '<div class="tab-panel" data-tab-panel="overview">'
      +   '<table class="kv-table"><tbody>'
      +     row("Name",        p.name)
      +     row("Description", p.description)
      +     row("Status",      '<span class="status-' + esc(p.status) + '">' + esc(p.status) + '</span>', true)
      +     row("Queue",       p.queue)
      +     row("Thread-id",   p.thread_id_template ? '<code>' + esc(p.thread_id_template) + '</code>' : null, true)
      +     row("Entry block", p.entry_block)
      +     row("Blocks",      p.blocks.length)
      +     row("Routes",      p.routes.length)
      +     ((p.parallel_groups || []).length
            ? row("Parallel groups",
                  p.parallel_groups.map(function (g) {
                    return '<code>' + esc(g.name) + '</code> [' + esc(g.join_strategy) + ']: ' +
                           g.members.map(esc).join(", ");
                  }).join("<br>"), true)
            : "")
      +     row("Last status", '<span class="status-' + esc(p.last_status) + '">' + (p.last_status == null ? "—" : esc(p.last_status)) + '</span>', true)
      +   '</tbody></table>'
      + '</div>'
      // blocks
      + '<div class="tab-panel" data-tab-panel="blocks" hidden>'  + blocksTable(p.blocks)  + '</div>'
      // routes
      + '<div class="tab-panel" data-tab-panel="routes" hidden>'  + routesTable(p.routes)  + '</div>'
      // graph
      + '<div class="tab-panel" data-tab-panel="graph"  hidden>'
      +   '<div class="process-graph" data-process-graph '
      +     'data-process-name="' + esc(p.name) + '" '
      +     'data-graph="' + esc(JSON.stringify(graphPayload)) + '">'
      +     '<div class="process-graph__hint">drag a node to reposition · layout saved per process</div>'
      +     '<svg class="process-graph__svg" xmlns="http://www.w3.org/2000/svg"></svg>'
      +   '</div>'
      + '</div>'
      // trigger
      + '<div class="tab-panel" data-tab-panel="trigger" hidden>'
      +   '<form class="trigger-form" data-trigger-process="' + esc(p.name) + '">'
      +     '<p class="trigger-form__hint">Send a one-shot input event into <code>' + esc(p.name) + '</code>. The event is delivered as if it had arrived through the matching interface.</p>'
      +     '<label class="trigger-form__label">Input event JSON</label>'
      +     '<textarea class="trigger-form__input" spellcheck="false" autocomplete="off" rows="10">{\n  "type": "lead.created",\n  "body": {}\n}</textarea>'
      +     '<div class="trigger-form__actions">'
      +       '<button type="button" class="action__btn"                            data-trigger-action="validate">validate JSON</button>'
      +       '<button type="button" class="action__btn action__btn--primary"      data-trigger-action="trigger">trigger</button>'
      +     '</div>'
      +     '<div class="trigger-form__status" aria-live="polite"></div>'
      +   '</form>'
      + '</div>';
  });

  function row(k, v, raw) {
    const cell = v == null ? "—" : (raw ? v : esc(v));
    return "<tr><td>" + esc(k) + "</td><td>" + cell + "</td></tr>";
  }

  function blocksTable(blocks) {
    if (!blocks.length) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No blocks defined.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Block</th><th>Interface</th><th>Call</th><th>Tags</th>' +
      '<th>Timeout</th><th>Retry</th><th>Contract</th><th>Secrets</th>' +
      '</tr></thead><tbody>';
    blocks.forEach(function (b) {
      out += "<tr>" +
        td(b.name) +
        td(W.blockKindLabel(b)) +
        '<td class="data-table__truncate">' + (b.call_summary == null ? "—" : esc(b.call_summary)) + "</td>" +
        '<td>' + W.blockBadges(b) + '</td>' +
        td(b.timeout_ms == null ? null : b.timeout_ms + " ms") +
        td(b.retry_policy) +
        td(b.contract) +
        td(b.secret_names && b.secret_names.length ? b.secret_names.join(", ") : null) +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  }

  function routesTable(routes) {
    if (!routes.length) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No routes defined.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>From</th><th>To</th><th>Condition</th><th>On failure</th><th>Enabled</th>' +
      '</tr></thead><tbody>';
    routes.forEach(function (r) {
      out += "<tr>" + td(r.from) + td(r.to) + td(r.condition) + td(r.on_failure) +
        "<td>" + (r.enabled ? "yes" : "no") + "</td></tr>";
    });
    out += "</tbody></table>";
    return out;
  }

  function td(v) { return "<td>" + (v == null ? "—" : esc(v)) + "</td>"; }
})();

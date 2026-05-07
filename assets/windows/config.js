(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("config", async function () {
    const [active, boot, commits] = await Promise.all([
      A.activeConfig(), A.bootConfig(), A.listCommits(50)
    ]);
    const drift = !!(active && boot && active.commit && boot.commit && active.commit.id !== boot.commit.id);
    const diffRows = (active && boot)
      ? window.ProuterdDiff.lines(boot.rendered || "", active.rendered || "")
      : null;

    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Config</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>active</b> #' + (active && active.commit ? esc(active.commit.id) : "—") + '</span>'
      +     '<span><b>boot</b> #'   + (boot   && boot.commit   ? esc(boot.commit.id)   : "—") + '</span>'
      +     '<span><b>drift</b> <span class="status-' + (drift ? "retrying" : "success") + '">' + (drift ? "yes" : "no") + '</span></span>'
      +     '<span><b>commits</b> ' + esc(commits.length) + '</span>'
      +   '</div>'
      + '</header>'
      + '<nav class="tabs" role="tablist">'
      +   '<button type="button" class="tab tab--active" data-tab="active">Active</button>'
      +   '<button type="button" class="tab"             data-tab="boot">Boot</button>'
      +   '<button type="button" class="tab"             data-tab="draft">Draft</button>'
      +   '<button type="button" class="tab"             data-tab="diff">Diff</button>'
      +   '<button type="button" class="tab"             data-tab="commits">Commits</button>'
      + '</nav>'

      + '<div class="tab-panel" data-tab-panel="active">' + renderRendered(active, drift, true) + '</div>'
      + '<div class="tab-panel" data-tab-panel="boot"  hidden>' + renderRendered(boot, false, false) + '</div>'
      + '<div class="tab-panel" data-tab-panel="draft" hidden>' +
            '<div class="logs__empty">No draft session — draft editing is read-only in this version.</div>' +
        '</div>'
      + '<div class="tab-panel" data-tab-panel="diff"  hidden>' + renderDiffPanel(active, boot, diffRows) + '</div>'
      + '<div class="tab-panel" data-tab-panel="commits" hidden>' + renderCommits(commits, active) + '</div>';
  });

  function renderRendered(view, showSaveBoot, isActive) {
    if (!view) {
      return '<div class="logs__empty">no ' + (isActive ? "active" : "boot") + ' config</div>';
    }
    const c = view.commit || {};
    const header = '<div class="config__header">' +
      '<span><b>commit</b> #' + esc(c.id) + '</span>' +
      '<span><b>checksum</b> ' + esc(c.short_checksum || "") + '</span>' +
      '<span><b>author</b> ' + (c.author == null ? "—" : esc(c.author)) + '</span>' +
      '<span><b>created</b> ' + esc(c.created_at || "") + '</span>' +
      (c.message ? '<span><b>message</b> ' + esc(c.message) + '</span>' : "") +
      '</div>';
    const actions = (showSaveBoot ? (
      '<div class="config__actions">' +
        '<button type="button" class="config__btn" data-config-action="save-boot" ' +
          'data-confirm="Save running config as the boot config?">Save as boot config</button>' +
        '<span class="config__hint">drift detected — boot will not match running until you save</span>' +
      '</div>') : "");
    return header + actions + '<pre class="config__pre">' + esc(view.rendered || "") + '</pre>';
  }

  function renderDiffPanel(active, boot, rows) {
    if (!active || !boot || !rows) {
      return '<div class="logs__empty">no diff available (need both active and boot)</div>';
    }
    const head = '<div class="config__header">' +
      '<span><b>left</b> #' + esc(boot.commit.id)   + ' (boot)</span>' +
      '<span><b>right</b> #' + esc(active.commit.id) + ' (active)</span>' +
      '</div>';
    return head + window.ProuterdDiff.render(rows);
  }

  function renderCommits(commits, active) {
    if (commits.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No commits yet.</td></tr></tbody></table>';
    }
    const activeId = active && active.commit && active.commit.id;
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Commit</th><th>Author</th><th>Message</th><th>Checksum</th><th>Created</th><th>Actions</th>' +
      '</tr></thead><tbody>';
    commits.forEach(function (c) {
      const isActive = activeId != null && c.id === activeId;
      const actions = isActive
        ? '<span class="status-success">active</span>'
        : '<a href="#" data-open-window="diff" data-open-resource="' + esc(c.id + "/" + activeId) + '">diff vs active</a>' +
          ' · ' +
          '<a href="#" data-config-action="rollback" data-commit-id="' + esc(c.id) + '" ' +
          'data-confirm="Rollback running config to commit #' + esc(c.id) + '?">rollback</a>';
      out += "<tr>" +
        "<td>#" + esc(c.id) + "</td>" +
        "<td>" + (c.author == null ? "—" : esc(c.author)) + "</td>" +
        "<td>" + (c.message == null ? "—" : esc(c.message)) + "</td>" +
        '<td class="artifacts__checksum">' + esc(c.short_checksum || "") + "</td>" +
        "<td>" + esc(c.created_at || "") + "</td>" +
        "<td>" + actions + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  }
})();

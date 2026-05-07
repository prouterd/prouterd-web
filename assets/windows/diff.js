(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // resourceId is "<left-id>/<right-id>"
  W.register("diff", async function (resource) {
    const m = String(resource || "").split("/");
    if (m.length !== 2 || !m[0] || !m[1]) {
      return '<div class="window-error">diff: expected resource format "left-id/right-id"</div>';
    }
    const d = await A.configDiff(m[0], m[1]);
    if (!d) return '<div class="window-error">commit not found</div>';

    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Diff: #' + esc(d.left.id) + ' → #' + esc(d.right.id) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>left</b> #'  + esc(d.left.id)  + ' (' + esc(d.left.short_checksum)  + ') ' + esc(d.left.message  || "") + '</span>'
      +     '<span><b>right</b> #' + esc(d.right.id) + ' (' + esc(d.right.short_checksum) + ') ' + esc(d.right.message || "") + '</span>'
      +   '</div>'
      + '</header>'
      + window.ProuterdDiff.render(d.rows);
  });
})();

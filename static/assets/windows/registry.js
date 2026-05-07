// windows/registry.js
//
// Per-window-type render registry. Each renderer is `async (resourceId)
// => htmlString`. The window manager calls `ProuterdWindows.render(type,
// resourceId)` instead of fetching server-rendered HTML.
//
// Stub renderers ship for window types that haven't been ported from
// the old ERB views yet — they show a clear placeholder instead of
// silently failing.

(function () {
  "use strict";

  const renderers = {};

  function register(type, fn) { renderers[type] = fn; }

  async function render(type, resourceId) {
    const fn = renderers[type];
    if (!fn) {
      return '<div class="window-error">' +
        'no renderer for window type "' + escapeHtml(type) + '"' +
        '</div>';
    }
    return await fn(resourceId);
  }

  function stub(type) {
    return function () {
      return '<div class="window-error">window type "' + escapeHtml(type) +
        '" is not yet ported to the static SPA — see static/assets/windows/' +
        '</div>';
    };
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  // Stubs for window types that aren't ported yet — populated by the
  // per-type files below. Each call to `register` overrides.
  [
    "interfaces", "blocks", "queues", "policies", "secrets",
    "config", "diff", "logs", "context", "artifacts", "trace",
    "step", "cli"
  ].forEach(function (t) { register(t, stub(t)); });

  window.ProuterdWindows = {
    register: register, render: render, escapeHtml: escapeHtml
  };
})();

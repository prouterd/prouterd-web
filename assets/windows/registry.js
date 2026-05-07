// windows/registry.js
//
// Per-window-type render registry. Each renderer is `async (resourceId)
// => htmlString`. The window manager calls `ProuterdWindows.render(type,
// resourceId)` to populate a window body. Renderers register themselves
// from their respective files in this directory.

(function () {
  "use strict";

  const renderers = {};

  function register(type, fn) { renderers[type] = fn; }

  async function render(type, resourceId) {
    const fn = renderers[type];
    if (!fn) {
      return '<div class="window-error">no renderer for window type "' +
        escapeHtml(type) + '"</div>';
    }
    return await fn(resourceId);
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  window.ProuterdWindows = {
    register: register, render: render, escapeHtml: escapeHtml
  };
})();

(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("context", async function (resource) {
    if (!resource) return '<div class="window-error">context: run uid required</div>';
    const ctx = await A.getRunContext(resource);
    if (!ctx) return '<div class="window-error">run ' + esc(resource) + ' not found</div>';

    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Context: ' + esc(resource) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><a href="#" data-open-window="run" data-open-resource="' + esc(resource) + '">open run inspector</a></span>'
      +   '</div>'
      + '</header>'
      + '<nav class="tabs" role="tablist">'
      +   '<button type="button" class="tab tab--active" data-tab="context">Context</button>'
      +   '<button type="button" class="tab"             data-tab="event">Input event</button>'
      + '</nav>'
      + '<div class="tab-panel" data-tab-panel="context">' +
            (ctx.context == null ? '<div class="logs__empty">empty context</div>' : window.ProuterdJsonTree.render(ctx.context)) +
        '</div>'
      + '<div class="tab-panel" data-tab-panel="event" hidden>' +
            (ctx.input_event == null ? '<div class="logs__empty">no input event</div>' : window.ProuterdJsonTree.render(ctx.input_event)) +
        '</div>';
  });
})();

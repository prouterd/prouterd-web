(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const esc = W.escapeHtml;

  W.register("trace", async function () {
    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Trace event</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span class="window-placeholder__hint">'
      +       'Statically walk routes for an event without executing any blocks. '
      +       'Routes whose matches read from runtime block outputs are marked '
      +       '<code>deferred</code> — those can only be evaluated at run time.'
      +     '</span>'
      +   '</div>'
      + '</header>'
      + '<form class="trigger-form" data-trace-form>'
      +   '<label class="trigger-form__label">Interface name (optional)</label>'
      +   '<input type="text" class="trigger-form__input" data-trace-interface '
      +     'autocomplete="off" spellcheck="false" placeholder="leads_in" '
      +     'style="min-height: 0; padding: 6px 8px;">'
      +   '<label class="trigger-form__label" style="margin-top: 8px;">Event JSON</label>'
      +   '<textarea class="trigger-form__input" data-trace-event spellcheck="false" '
      +     'autocomplete="off" rows="10">{\n  "type": "lead.created",\n  "body": {}\n}</textarea>'
      +   '<div class="trigger-form__actions">'
      +     '<button type="button" class="action__btn"                       data-trace-action="validate">validate JSON</button>'
      +     '<button type="button" class="action__btn action__btn--primary" data-trace-action="trace">trace</button>'
      +   '</div>'
      +   '<div class="trigger-form__status" data-trace-status></div>'
      + '</form>'
      + '<div class="trace-result" data-trace-result></div>';
  });
})();

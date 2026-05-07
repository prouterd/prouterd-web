(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const esc = W.escapeHtml;

  // resourceId is the cli session_id (window_manager generates one
  // when the user opens a fresh CLI window).
  W.register("cli", async function (sessionId) {
    if (!sessionId) sessionId = "cli-" + Date.now().toString(36);
    return ''
      + '<div class="cli" data-cli-session="' + esc(sessionId) + '">'
      +   '<div class="cli__output" role="log" aria-live="polite"></div>'
      +   '<div class="cli__inputline">'
      +     '<span class="cli__prompt">prouter# </span>'
      +     '<input class="cli__input" type="text" '
      +       'autocomplete="off" autocorrect="off" autocapitalize="off" '
      +       'spellcheck="false" aria-label="CLI input">'
      +   '</div>'
      + '</div>';
  });
})();

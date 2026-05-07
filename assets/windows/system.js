(function () {
  "use strict";
  const W = window.ProuterdWindows;
  const A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("system", async function () {
    const s = await A.status();
    function row(k, v) { return "<tr><td>" + esc(k) + "</td><td>" + (v == null ? "—" : esc(v)) + "</td></tr>"; }
    return '<table class="kv-table"><tbody>' +
      row("Router",         s.router) +
      row("Healthy",        s.healthy ? "yes" : "no") +
      row("Core version",   s.core_version) +
      row("Active commit",  s.active_commit && ("#" + s.active_commit)) +
      row("Boot commit",    s.boot_commit   && ("#" + s.boot_commit)) +
      row("Config drift",   s.config_drift ? "yes" : "no") +
      row("Workers",        s.workers) +
      row("Queue depth",    s.queue_depth) +
      row("Uptime (s)",     s.uptime_seconds) +
      "</tbody></table>";
  });
})();

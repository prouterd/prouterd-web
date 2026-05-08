// windows/registry.js
//
// Per-window-type render registry. Each renderer is `async (resourceId)
// => htmlString`. The window manager calls `ProuterdWindows.render(type,
// resourceId)` to populate a window body. Renderers register themselves
// from their respective files in this directory.

(function () {
  "use strict";

  const renderers = {};
  const appenders = {};

  function register(type, fn) { renderers[type] = fn; }

  // Optional incremental-update path. When a window subscribes to a
  // live topic, by default each event triggers a full re-render via
  // hydrateBody. A renderer may opt into incremental mode by also
  // registering an appender — invoked with (ws, eventPayload, topic).
  // Return true to indicate the event was handled (skip the full
  // refresh); false / throw to fall back to the default debounced
  // hydrateBody. Used by the Logs window so chatty runs don't refetch
  // the entire log buffer on every appended line.
  function registerAppender(type, fn) { appenders[type] = fn; }

  function appender(type) { return appenders[type]; }

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

  // ----- Phase-37 directive badges (shared) -----
  // The standalone Blocks window and the Process Inspector → Blocks
  // tab both want the same tag column for skip_when / vars / fan_out /
  // agentic / pause / barrier / max_cost_usd. Defining the rendering
  // here keeps the two views in lock-step.

  function blockKindLabel(b) {
    if (b.pause_reason) return "pause";
    if (b.barrier)     return "parallel barrier";
    return b.interface_label;
  }

  function blockBadges(b) {
    const tags = [];
    if (b.pause_reason)              tags.push(badge("pause",     "warn",   b.pause_reason));
    if (b.barrier)                   tags.push(badge("barrier",   "info",   b.barrier.join_strategy));
    if (b.skip_when)                 tags.push(badge("skip-when", "muted",  null));
    if (b.fan_out)                   tags.push(badge("fan-out",   "info",   fanOutHint(b.fan_out)));
    if (b.agentic)                   tags.push(badge("agentic",   "accent", agenticHint(b.agentic)));
    if (b.vars && Object.keys(b.vars).length) {
      tags.push(badge("vars", "muted", String(Object.keys(b.vars).length)));
    }
    if (b.max_cost_usd != null)      tags.push(badge("$" + b.max_cost_usd.toFixed(2), "warn", "max-cost-usd cap"));
    return tags.length ? tags.join(" ") : "—";
  }

  function agenticHint(a) {
    const tools = (a.allowed_tools || []).length;
    return tools ? tools + " tool" + (tools === 1 ? "" : "s") : "no tools";
  }

  function fanOutHint(f) {
    const parts = ["→ " + f.into];
    if (f.maps && f.maps.length) parts.push(f.maps.length + " maps");
    if (f.dedupe)                parts.push("dedupe " + (f.dedupe.by || ""));
    if (f.rate_limit)            parts.push("rate " + f.rate_limit.n + "/" + (f.rate_limit.window_ms || "") + "ms");
    return parts.join(" · ");
  }

  function badge(label, kind, hint) {
    const title = hint ? ' title="' + escapeHtml(String(hint)) + '"' : "";
    return '<span class="badge badge--' + escapeHtml(kind) + '"' + title + '>' + escapeHtml(label) + '</span>';
  }

  window.ProuterdWindows = {
    register: register, registerAppender: registerAppender,
    render: render, appender: appender,
    escapeHtml: escapeHtml,
    blockKindLabel: blockKindLabel, blockBadges: blockBadges
  };
})();

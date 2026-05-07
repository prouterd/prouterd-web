// boot.js
//
// Bootstraps the static SPA: redirects to login if no daemon is
// configured, fills the top-bar status pills from /v1/status, wires
// the logout link.

(function () {
  "use strict";

  document.addEventListener("DOMContentLoaded", async function () {
    if (!window.ProuterdCore) return;
    const cfg = window.ProuterdCore.config();
    if (!cfg.url) {
      window.location.href = "login.html";
      return;
    }

    const logoutLink = document.getElementById("top-bar-logout");
    if (logoutLink) {
      logoutLink.addEventListener("click", function (e) {
        e.preventDefault();
        window.ProuterdCore.logout();
      });
    }

    refreshStatus();
    setInterval(refreshStatus, 5000);
  });

  async function refreshStatus() {
    try {
      const s = await window.ProuterdAdapter.status();
      setText("top-bar-router", s.router || "prouterd");
      setText("top-bar-active", "active: #" + (s.active_commit || "—"));
      setText("top-bar-boot",   "boot: #"   + (s.boot_commit   || "—"));
      const drift = document.getElementById("top-bar-drift");
      if (drift) {
        drift.textContent = "drift: " + (s.config_drift ? "yes" : "no");
        drift.className = "top-bar__stat top-bar__stat--" + (s.config_drift ? "warn" : "ok");
      }
      setText("top-bar-workers", "workers: " + (s.workers ?? "—"));
      setText("top-bar-queue",   "queue: "   + (s.queue_depth ?? "—"));
    } catch (e) { /* swallow — health pill flips via ws_client */ }
  }

  function setText(id, v) {
    const el = document.getElementById(id);
    if (el) el.textContent = v;
  }
})();

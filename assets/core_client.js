// core_client.js
//
// Daemon URL + WS / download URL helpers. Auth lives entirely in an
// HttpOnly cookie set by POST /v1/login (see login.html); the SPA
// holds nothing sensitive in JS, so an XSS in console code can't
// leak the credential.
//
// Requires same-origin deployment with the daemon (or a same-origin
// reverse proxy in front). The daemon's `--console-dir PATH` flag is
// the canonical dev/prod single-process setup: `prouterd
// --console-dir ./prouterd-web` serves the SPA and /v1 from one
// host, cookies just work, no CORS knobs needed.

(function () {
  "use strict";

  const STORAGE_KEY = "prouterd.core";

  function config() {
    try { return JSON.parse(sessionStorage.getItem(STORAGE_KEY) || "{}"); }
    catch (e) { return {}; }
  }

  function setConfig(cfg) {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(cfg || {}));
  }

  function clearConfig() {
    sessionStorage.removeItem(STORAGE_KEY);
  }

  function redirectToLogin() {
    const next = encodeURIComponent(
      window.location.pathname.replace(/^.*\//, "") + window.location.search
    );
    window.location.href = "login.html" + (next ? "?next=" + next : "");
  }

  function requireConfig() {
    const cfg = config();
    if (!cfg.url) {
      redirectToLogin();
      throw new Error("not configured");
    }
    return cfg;
  }

  function wsUrl(path) {
    const cfg = requireConfig();
    return cfg.url.replace(/^http/, "ws") + path;
  }

  // Plain HTTP URL for artifact downloads (browser navigates to it
  // via <a download>). Cookie auto-attaches the same way it does for
  // any other navigation to the daemon's origin.
  function downloadUrl(path) {
    const cfg = config();
    if (!cfg.url) return "";
    return cfg.url + path;
  }

  // POST /v1/logout to revoke the server-side session, then drop our
  // local URL hint and bounce to login. Best-effort: a network error
  // doesn't block the local clear.
  async function logout() {
    const cfg = config();
    if (cfg.url) {
      try {
        await fetch(cfg.url + "/v1/logout", { method: "POST", credentials: "include" });
      } catch (e) { /* ignore */ }
    }
    clearConfig();
    redirectToLogin();
  }

  window.ProuterdCore = {
    config: config, setConfig: setConfig, clearConfig: clearConfig,
    wsUrl: wsUrl, downloadUrl: downloadUrl, logout: logout
  };
})();

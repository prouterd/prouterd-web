// core_client.js
//
// Session storage + WS URL helper. The console talks to the daemon
// over WS-RPC (see ws_client.js); the only HTTP request the SPA makes
// is the artifact-download anchor, which uses downloadUrl().
//
// Daemon URL + bearer token are populated by login.html into
// sessionStorage and read here. logout() clears both and bounces to
// the login page.

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
    const wsBase = cfg.url.replace(/^http/, "ws");
    let url = wsBase + path;
    if (cfg.token) {
      url += (url.indexOf("?") >= 0 ? "&" : "?") + "token=" + encodeURIComponent(cfg.token);
    }
    return url;
  }

  // The one HTTP touchpoint left: artifact downloads. The browser
  // navigates to this URL via <a download>, so we embed the bearer in
  // the query string the same way as the WS handshake.
  function downloadUrl(path) {
    const cfg = config();
    if (!cfg.url) return "";
    let url = cfg.url + path;
    if (cfg.token) {
      url += (url.indexOf("?") >= 0 ? "&" : "?") + "token=" + encodeURIComponent(cfg.token);
    }
    return url;
  }

  function logout() {
    clearConfig();
    redirectToLogin();
  }

  window.ProuterdCore = {
    config: config, setConfig: setConfig, clearConfig: clearConfig,
    wsUrl: wsUrl, downloadUrl: downloadUrl, logout: logout
  };
})();

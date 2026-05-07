// core_client.js
//
// Frontend HTTP + WebSocket client. Daemon URL + bearer token are stored
// in sessionStorage by login.html. Every fetch / WS open includes the
// bearer; 401 redirects back to login.

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

  async function fetchJson(path, opts) {
    const cfg = requireConfig();
    const headers = Object.assign({ "Accept": "application/json" }, (opts && opts.headers) || {});
    if (cfg.token) headers["Authorization"] = "Bearer " + cfg.token;
    const init = Object.assign({}, opts, { headers });
    let res;
    try { res = await fetch(cfg.url + path, init); }
    catch (e) { throw new Error("network error: " + e.message); }

    if (res.status === 401) { clearConfig(); redirectToLogin(); throw new Error("unauthorized"); }
    if (res.status === 404) { const e = new Error("not found"); e.status = 404; throw e; }
    if (!res.ok) {
      const text = await res.text().catch(function () { return ""; });
      throw new Error("HTTP " + res.status + (text ? ": " + text : ""));
    }
    if (res.status === 204) return null;
    const ct = (res.headers.get("content-type") || "").split(";")[0].trim();
    if (ct === "application/json") return await res.json();
    return await res.text();
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

  function logout() {
    clearConfig();
    redirectToLogin();
  }

  window.ProuterdCore = {
    config: config, setConfig: setConfig, clearConfig: clearConfig,
    fetchJson: fetchJson, wsUrl: wsUrl, logout: logout
  };
})();

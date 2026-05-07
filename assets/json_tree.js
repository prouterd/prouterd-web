// json_tree.js
//
// Renders a parsed JSON value as collapsible HTML using native
// <details>/<summary>. Hashes and arrays nest, scalars get typed
// <span>s so the stylesheet can colour them by type. All terminal
// text is HTML-escaped.

(function () {
  "use strict";

  const DEFAULT_OPEN_DEPTH = 2;

  function render(value, opts) {
    opts = opts || {};
    const openDepth = opts.openDepth == null ? DEFAULT_OPEN_DEPTH : opts.openDepth;
    return '<div class="json">' + node(value, 0, openDepth) + "</div>";
  }

  function node(v, depth, openDepth) {
    if (v === null || v === undefined) return '<span class="json__null">null</span>';
    if (Array.isArray(v))               return arrayNode(v, depth, openDepth);
    if (typeof v === "object")          return objectNode(v, depth, openDepth);
    if (typeof v === "string")          return '<span class="json__string">"' + esc(v) + '"</span>';
    if (typeof v === "number")          return '<span class="json__number">' + esc(String(v)) + "</span>";
    if (typeof v === "boolean")         return '<span class="json__bool">' + (v ? "true" : "false") + "</span>";
    return '<span class="json__string">"' + esc(String(v)) + '"</span>';
  }

  function objectNode(obj, depth, openDepth) {
    const keys = Object.keys(obj);
    if (keys.length === 0) return '<span class="json__empty">{}</span>';
    const summary = '<summary>' +
      '<span class="json__brace">{</span>' +
      '<span class="json__count">' + keys.length + " " + plural("key", keys.length) + '</span>' +
      '<span class="json__brace">}</span>' +
      '</summary>';
    const rows = keys.map(function (k) {
      return '<div class="json__row">' +
        '<span class="json__key">' + esc(k) + '</span>' +
        '<span class="json__sep">:</span> ' +
        node(obj[k], depth + 1, openDepth) +
        '</div>';
    }).join("");
    const open = depth < openDepth ? " open" : "";
    return '<details class="json__node json__node--object"' + open + ">" +
      summary + '<div class="json__body">' + rows + "</div></details>";
  }

  function arrayNode(arr, depth, openDepth) {
    if (arr.length === 0) return '<span class="json__empty">[]</span>';
    const summary = '<summary>' +
      '<span class="json__brace">[</span>' +
      '<span class="json__count">' + arr.length + " " + plural("item", arr.length) + '</span>' +
      '<span class="json__brace">]</span>' +
      '</summary>';
    const rows = arr.map(function (v, i) {
      return '<div class="json__row">' +
        '<span class="json__index">' + i + '</span>' +
        '<span class="json__sep">:</span> ' +
        node(v, depth + 1, openDepth) +
        '</div>';
    }).join("");
    const open = depth < openDepth ? " open" : "";
    return '<details class="json__node json__node--array"' + open + ">" +
      summary + '<div class="json__body">' + rows + "</div></details>";
  }

  function plural(noun, n) { return n === 1 ? noun : noun + "s"; }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  window.ProuterdJsonTree = { render: render };
})();

// config_diff.js
//
// Line-oriented unified diff using a simple O(NM) LCS, returning rows
// the diff renderer (see render_diff in window_manager) can paint.
// Each row: { action: "=" | "-" | "+", text, left_no, right_no }.

(function () {
  "use strict";

  function lines(leftText, rightText) {
    const a = (leftText  || "").split("\n");
    const b = (rightText || "").split("\n");
    const n = a.length, m = b.length;

    // dp[i][j] = LCS length of a[i..] and b[j..]
    const dp = new Array(n + 1);
    for (let i = 0; i <= n; i++) dp[i] = new Int32Array(m + 1);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        if (a[i] === b[j]) dp[i][j] = dp[i + 1][j + 1] + 1;
        else dp[i][j] = Math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }

    const out = [];
    let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) {
        out.push({ action: "=", text: a[i], left_no: i + 1, right_no: j + 1 });
        i++; j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        out.push({ action: "-", text: a[i], left_no: i + 1, right_no: null });
        i++;
      } else {
        out.push({ action: "+", text: b[j], left_no: null, right_no: j + 1 });
        j++;
      }
    }
    while (i < n) { out.push({ action: "-", text: a[i], left_no: i + 1, right_no: null }); i++; }
    while (j < m) { out.push({ action: "+", text: b[j], left_no: null, right_no: j + 1 }); j++; }
    return out;
  }

  function renderRows(rows) {
    if (!rows || rows.length === 0 || rows.every(function (r) { return r.action === "="; })) {
      return '<div class="logs__empty">configs are identical</div>';
    }
    let out = '<div class="diff">';
    rows.forEach(function (r) {
      const cls = r.action === "-" ? "diff__row diff__row--del"
                : r.action === "+" ? "diff__row diff__row--ins"
                                   : "diff__row diff__row--ctx";
      out += '<div class="' + cls + '">' +
        '<span class="diff__no">' + (r.left_no  == null ? "" : r.left_no)  + '</span>' +
        '<span class="diff__no">' + (r.right_no == null ? "" : r.right_no) + '</span>' +
        '<span class="diff__text">' + escHtml(r.text || "") + '</span>' +
        '</div>';
    });
    out += "</div>";
    return out;
  }

  function escHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  window.ProuterdDiff = { lines: lines, render: renderRows };
})();

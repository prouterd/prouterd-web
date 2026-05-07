(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  W.register("artifacts", async function (resource) {
    if (!resource) {
      const runs = await A.listRuns({ limit: 30 });
      return runPicker("artifacts", runs);
    }
    const arts = await A.getRunArtifacts(resource);

    let out = ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Artifacts: ' + esc(resource) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>count</b> ' + esc(arts.length) + '</span>'
      +     '<span><a href="#" data-open-window="run" data-open-resource="' + esc(resource) + '">open run inspector</a></span>'
      +   '</div>'
      + '</header>'
      + '<table class="data-table"><thead><tr>'
      +   '<th>Name</th><th>Block</th><th>Step</th><th>Size</th><th>Type</th>'
      +   '<th>Checksum</th><th>Created</th><th>Download</th>'
      + '</tr></thead><tbody>';
    if (arts.length === 0) {
      out += '<tr><td colspan="8" class="data-table__empty">No artifacts.</td></tr>';
    } else {
      arts.forEach(function (a) {
        out += "<tr>" +
          "<td>" + esc(a.name) + "</td>" +
          "<td>" + esc(a.block_name) + "</td>" +
          "<td>" + esc(a.step_id) + "</td>" +
          "<td>" + esc(formatBytes(a.size_bytes)) + "</td>" +
          "<td>" + (a.content_type == null ? "—" : esc(a.content_type)) + "</td>" +
          '<td class="artifacts__checksum">' + (a.checksum == null ? "—" : esc(a.checksum)) + "</td>" +
          "<td>" + esc(a.created_at || "") + "</td>" +
          '<td><a href="' + esc(A.artifactDownloadUrl(a.id)) + '" download="' + esc(a.name) + '">↓</a></td>' +
          "</tr>";
      });
    }
    out += "</tbody></table>";
    return out;
  });

  function runPicker(kind, runs) {
    let out = ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">' + (kind === "logs" ? "Logs" : "Artifacts") + ' · pick a run</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>recent runs</b> ' + esc(runs.length) + '</span>'
      +     '<span class="window-placeholder__hint">click a row to open this run\'s ' + esc(kind) + ' window</span>'
      +   '</div>'
      + '</header>';
    if (runs.length === 0) {
      return out + '<table class="data-table"><tbody><tr><td class="data-table__empty">No runs yet.</td></tr></tbody></table>';
    }
    out += '<table class="data-table"><thead><tr>' +
      '<th>Run</th><th>Process</th><th>Status</th><th>Started</th><th>Duration</th>' +
      '</tr></thead><tbody>';
    runs.forEach(function (r) {
      out += '<tr class="data-table__row--clickable" data-open-window="' + esc(kind) + '" ' +
             'data-open-resource="' + esc(r.run_uid) + '">' +
        "<td>" + esc(r.run_uid) + "</td>" +
        "<td>" + esc(r.process_name) + "</td>" +
        '<td class="status-' + esc(r.status) + '">' + esc(r.status) + '</td>' +
        "<td>" + (r.started_at == null ? "—" : esc(r.started_at)) + "</td>" +
        "<td>" + (r.duration_ms == null ? "—" : esc(r.duration_ms + " ms")) + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  }

  function formatBytes(n) {
    if (n == null) return "—";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / 1024 / 1024).toFixed(1) + " MB";
  }
})();

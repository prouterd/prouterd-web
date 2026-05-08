(function () {
  "use strict";
  const W = window.ProuterdWindows, A = window.ProuterdAdapter;
  const esc = W.escapeHtml;

  // resourceId is "<run_uid>/<step_id>"
  W.register("step", async function (resource) {
    const m = String(resource || "").split("/");
    if (m.length < 2 || !m[0] || !m[1]) {
      return '<div class="window-error">step: expected resource format "run_uid/step_id"</div>';
    }
    const runUid = m[0], stepId = m[1];

    const [step, stepLogs, stepArtifacts] = await Promise.all([
      A.getStep(runUid, stepId),
      A.getStepLogs(runUid, { step_id: stepId }),
      A.getRunArtifacts(runUid, { step_id: stepId })
    ]);
    if (!step) return '<div class="window-error">step ' + esc(stepId) + ' not found in run ' + esc(runUid) + '</div>';

    const toolCalls = (step.output_json && Array.isArray(step.output_json.tool_calls))
      ? step.output_json.tool_calls : null;

    return ''
      + '<header class="inspector-header">'
      +   '<div class="inspector-header__title">Step ' + esc(step.id) + ': ' + esc(step.block_name) + ' · run ' + esc(runUid) + '</div>'
      +   '<div class="inspector-header__meta">'
      +     '<span><b>status</b> <span class="status-' + esc(step.status) + '">' + esc(step.status) + '</span></span>'
      +     '<span><b>attempt</b> ' + esc(step.attempt) + '</span>'
      +     '<span><b>image</b> '   + (step.image == null ? "—" : esc(step.image)) + '</span>'
      +     '<span><b>exit</b> '    + (step.exit_code == null ? "—" : esc(step.exit_code)) + '</span>'
      +     '<span><b>duration</b> '+ (step.duration_ms == null ? "—" : esc(step.duration_ms + " ms")) + '</span>'
      +     (step.error_type ? '<span><b>error</b> <span class="status-failed">' + esc(step.error_type) + '</span></span>' : "")
      +     '<span><a href="#" data-open-window="run" data-open-resource="' + esc(runUid) + '">open run inspector</a></span>'
      +   '</div>'
      +   '<div class="inspector-header__actions">'
      +     '<button type="button" class="action__btn" data-run-action="replay-from" ' +
            'data-run-uid="' + esc(runUid) + '" data-from-block="' + esc(step.block_name) + '" ' +
            'data-confirm="Replay run ' + esc(runUid) + " starting at block '" + esc(step.block_name) + "'?\">" +
            'replay from this step</button>'
      +   '</div>'
      + '</header>'
      + '<nav class="tabs" role="tablist">'
      +   '<button type="button" class="tab tab--active" data-tab="input">Input</button>'
      +   '<button type="button" class="tab"             data-tab="output">Output</button>'
      +   (toolCalls ? '<button type="button" class="tab" data-tab="tools">Tool calls (' + toolCalls.length + ')</button>' : "")
      +   '<button type="button" class="tab"             data-tab="logs">Logs</button>'
      +   '<button type="button" class="tab"             data-tab="artifacts">Artifacts</button>'
      + '</nav>'
      + '<div class="tab-panel" data-tab-panel="input">' +
            (step.input_json == null ? '<div class="logs__empty">no input recorded</div>' : window.ProuterdJsonTree.render(step.input_json)) +
        '</div>'
      + '<div class="tab-panel" data-tab-panel="output" hidden>' +
            (step.output_json == null ? '<div class="logs__empty">no output recorded</div>' : window.ProuterdJsonTree.render(step.output_json)) +
            (step.error_message ? '<div class="step__error"><div class="step__error-label">Error message</div><pre class="step__error-body">' + esc(step.error_message) + '</pre></div>' : "") +
        '</div>'
      + (toolCalls ? '<div class="tab-panel" data-tab-panel="tools" hidden>' + renderToolCalls(toolCalls) + '</div>' : "")
      + '<div class="tab-panel" data-tab-panel="logs" hidden>' +
            renderLogs(stepLogs, true) +
        '</div>'
      + '<div class="tab-panel" data-tab-panel="artifacts" hidden>' +
            renderStepArtifacts(stepArtifacts) +
        '</div>';
  });

  // Render the tool_calls history collected during an agentic block run.
  // Each entry is a {name, input, output, error?} hash; show them as a
  // numbered timeline with collapsible JSON for input + output.
  function renderToolCalls(calls) {
    if (!calls.length) {
      return '<div class="logs__empty">no tool calls</div>';
    }
    let out = '<div class="tool-calls">';
    calls.forEach(function (c, i) {
      const errClass = c.error ? " tool-call--error" : "";
      out += '<div class="tool-call' + errClass + '">';
      out +=   '<div class="tool-call__head">';
      out +=     '<span class="tool-call__index">#' + (i + 1) + '</span>';
      out +=     '<span class="tool-call__name">' + esc(c.name || "?") + '</span>';
      if (c.error) out += '<span class="tool-call__error">' + esc(c.error) + '</span>';
      out +=   '</div>';
      out +=   '<div class="tool-call__body">';
      out +=     '<div class="tool-call__pane"><div class="tool-call__label">input</div>' +
                  (c.input == null ? '<div class="logs__empty">∅</div>' : window.ProuterdJsonTree.render(c.input)) +
                '</div>';
      out +=     '<div class="tool-call__pane"><div class="tool-call__label">output</div>' +
                  (c.output == null ? '<div class="logs__empty">∅</div>' : window.ProuterdJsonTree.render(c.output)) +
                '</div>';
      out +=   '</div>';
      out += '</div>';
    });
    out += '</div>';
    return out;
  }

  function renderLogs(logs, single) {
    if (logs.length === 0) {
      return '<div class="logs"><div class="logs__empty">no log entries</div></div>';
    }
    let out = '<div class="logs">';
    logs.forEach(function (l) {
      out += '<div class="logs__line logs__line--' + esc(l.stream) + '">' +
        '<span class="logs__ts">'      + esc(formatTs(l.created_at)) + '</span>' +
        '<span class="logs__stream">'  + esc(l.stream) + '</span>' +
        (single ? "" : '<span class="logs__step">step ' + (l.step_id == null ? "—" : esc(l.step_id)) + '</span>') +
        '<span class="logs__content">' + esc(l.content || "") + '</span>' +
        '</div>';
    });
    out += "</div>";
    return out;
  }

  function renderStepArtifacts(arts) {
    if (arts.length === 0) {
      return '<table class="data-table"><tbody><tr><td class="data-table__empty">No artifacts for this step.</td></tr></tbody></table>';
    }
    let out = '<table class="data-table"><thead><tr>' +
      '<th>Name</th><th>Size</th><th>Type</th><th>Created</th>' +
      '</tr></thead><tbody>';
    arts.forEach(function (a) {
      out += "<tr>" +
        "<td>" + esc(a.name) + "</td>" +
        "<td>" + esc(formatBytes(a.size_bytes)) + "</td>" +
        "<td>" + (a.content_type == null ? "—" : esc(a.content_type)) + "</td>" +
        "<td>" + esc(a.created_at || "") + "</td>" +
        "</tr>";
    });
    out += "</tbody></table>";
    return out;
  }

  function formatTs(ts) {
    if (ts == null) return "";
    try {
      const d = new Date(ts);
      return d.toISOString().slice(11, 23);
    } catch (e) { return String(ts); }
  }

  function formatBytes(n) {
    if (n == null) return "—";
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / 1024 / 1024).toFixed(1) + " MB";
  }
})();

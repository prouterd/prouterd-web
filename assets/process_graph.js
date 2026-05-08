// process_graph.js
//
// Visual graph view for a process: blocks as nodes, routes as edges.
// Auto-layout on first render (longest-path layering left → right),
// drag-to-reposition with per-process persistence in localStorage.
//
// Mounts on every container with `[data-process-graph]` that appears in
// the workspace, mirroring the cli.js MutationObserver pattern: works
// across hydrate / re-hydrate without stacking handlers.

(function () {
  "use strict";

  const NODE_W = 140;
  const NODE_H = 44;
  const H_GAP  = 80;
  const V_GAP  = 24;
  const PAD    = 24;
  const STORAGE_PREFIX = "prouterd.web.graph.";
  const NS = "http://www.w3.org/2000/svg";

  document.addEventListener("DOMContentLoaded", function () {
    const workspace = document.getElementById("workspace");
    if (!workspace) return;

    document.querySelectorAll("[data-process-graph]").forEach(initGraph);

    const observer = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (node) {
          if (node.nodeType !== 1) return;
          if (node.matches && node.matches("[data-process-graph]")) initGraph(node);
          if (node.querySelectorAll) {
            node.querySelectorAll("[data-process-graph]").forEach(initGraph);
          }
        });
      });
    });
    observer.observe(workspace, { childList: true, subtree: true });
  });

  function initGraph(container) {
    if (container.dataset.graphInit === "1") return;
    container.dataset.graphInit = "1";

    const svg = container.querySelector(".process-graph__svg");
    if (!svg) return;

    let data;
    try { data = JSON.parse(container.dataset.graph || ""); }
    catch (e) { showMessage(svg, "graph payload invalid"); return; }

    const processName = container.dataset.processName || "";
    const nodes = (data.nodes || []).map(function (n) {
      return Object.assign({}, n, { x: 0, y: 0 });
    });
    const edges = (data.edges || []).filter(function (e) {
      return idIn(nodes, e.from) && idIn(nodes, e.to);
    });

    if (nodes.length === 0) { showMessage(svg, "no blocks to render"); return; }

    const auto = computeLayout(nodes, edges);
    const saved = loadSaved(processName);
    nodes.forEach(function (n) {
      const a = auto[n.id] || { x: PAD, y: PAD };
      const s = saved[n.id];
      n.x = s ? s.x : a.x;
      n.y = s ? s.y : a.y;
    });

    render(svg, nodes, edges, function () { saveLayout(processName, nodes); });
  }

  function idIn(nodes, id) {
    for (let i = 0; i < nodes.length; i++) if (nodes[i].id === id) return true;
    return false;
  }

  // Longest-path layering: layer(n) = 1 + max(layer(predecessors)).
  // Cycles (a route loops back) are broken implicitly via the visited
  // set — gives an approximate but stable layering for the operator's
  // mental model.
  function computeLayout(nodes, edges) {
    const ins = new Map();
    nodes.forEach(function (n) { ins.set(n.id, []); });
    edges.forEach(function (e) { ins.get(e.to).push(e.from); });

    const layer = new Map();
    function layerOf(id, stack) {
      if (layer.has(id)) return layer.get(id);
      if (stack.has(id)) return 0;
      stack.add(id);
      let max = 0;
      ins.get(id).forEach(function (p) {
        const v = layerOf(p, stack) + 1;
        if (v > max) max = v;
      });
      stack.delete(id);
      layer.set(id, max);
      return max;
    }
    nodes.forEach(function (n) { layerOf(n.id, new Set()); });

    const buckets = new Map();
    nodes.forEach(function (n) {
      const L = layer.get(n.id) || 0;
      if (!buckets.has(L)) buckets.set(L, []);
      buckets.get(L).push(n);
    });

    const out = {};
    Array.from(buckets.keys()).sort(function (a, b) { return a - b; }).forEach(function (L) {
      buckets.get(L).forEach(function (n, i) {
        out[n.id] = {
          x: PAD + L * (NODE_W + H_GAP),
          y: PAD + i * (NODE_H + V_GAP)
        };
      });
    });
    return out;
  }

  function render(svg, nodes, edges, onChange) {
    while (svg.firstChild) svg.removeChild(svg.firstChild);

    const defs = el("defs");
    const marker = el("marker", {
      id: "pg-arrow", viewBox: "0 0 10 10",
      refX: "10", refY: "5",
      markerWidth: "6", markerHeight: "6",
      orient: "auto-start-reverse"
    });
    marker.appendChild(el("path", {
      d: "M0,0 L10,5 L0,10 z",
      fill: "context-stroke",
      class: "pg-arrow"
    }));
    defs.appendChild(marker);
    svg.appendChild(defs);

    const edgeLayer = el("g", { class: "pg-edges" });
    const nodeLayer = el("g", { class: "pg-nodes" });
    svg.appendChild(edgeLayer);
    svg.appendChild(nodeLayer);

    const byId = new Map();
    nodes.forEach(function (n) { byId.set(n.id, n); });

    const edgeEls = edges.map(function (e) {
      let cls = "pg-edge";
      if (e.on_failure)      cls += " pg-edge--failure";
      if (e.enabled === false) cls += " pg-edge--disabled";
      const path = el("path", { class: cls, "marker-end": "url(#pg-arrow)" });
      if (e.condition) path.setAttribute("data-cond", e.condition);
      edgeLayer.appendChild(path);
      return { spec: e, path: path };
    });

    const nodeEls = nodes.map(function (n) {
      const kind = n.kind || "block";
      const cls = ["pg-node", "pg-node--kind-" + kind];
      if (n.entry) cls.push("pg-node--entry");
      if (n.agentic)   cls.push("pg-node--agentic");
      if (n.fan_out)   cls.push("pg-node--fanout");
      if (n.skip_when) cls.push("pg-node--skipwhen");
      const g = el("g", {
        class: cls.join(" "),
        "data-node-id": n.id
      });
      g.appendChild(el("rect", {
        class: "pg-node-rect pg-node-rect--" + (n.status || "ready"),
        width: NODE_W, height: NODE_H, rx: kind === "barrier" ? 14 : 4
      }));
      const label = el("text", {
        class: "pg-node-text", x: NODE_W / 2, y: 18, "text-anchor": "middle"
      });
      label.textContent = n.label;
      g.appendChild(label);
      // Sub-line: barrier shows "parallel · <strategy>"; pause shows
      // "pause"; otherwise the interface label.
      let sub = null;
      if (kind === "barrier") sub = "parallel barrier";
      else if (kind === "pause") sub = "pause";
      else if (n.interface) sub = n.interface;
      if (sub) {
        const subEl = el("text", {
          class: "pg-node-text pg-node-text--sub",
          x: NODE_W / 2, y: 34, "text-anchor": "middle"
        });
        subEl.textContent = sub;
        g.appendChild(subEl);
      }
      nodeLayer.appendChild(g);
      return { spec: n, el: g };
    });

    function place() {
      nodeEls.forEach(function (ne) {
        ne.el.setAttribute("transform", "translate(" + ne.spec.x + "," + ne.spec.y + ")");
      });
      edgeEls.forEach(function (ee) {
        const a = byId.get(ee.spec.from);
        const b = byId.get(ee.spec.to);
        const x1 = a.x + NODE_W;
        const y1 = a.y + NODE_H / 2;
        const x2 = b.x;
        const y2 = b.y + NODE_H / 2;
        const dx = Math.max(40, (x2 - x1) / 2);
        ee.path.setAttribute("d",
          "M" + x1 + "," + y1 +
          " C" + (x1 + dx) + "," + y1 +
          " "  + (x2 - dx) + "," + y2 +
          " "  + x2 + "," + y2);
      });
      let maxX = 0, maxY = 0;
      nodes.forEach(function (n) {
        if (n.x + NODE_W > maxX) maxX = n.x + NODE_W;
        if (n.y + NODE_H > maxY) maxY = n.y + NODE_H;
      });
      svg.setAttribute("width",  maxX + PAD);
      svg.setAttribute("height", maxY + PAD);
    }
    place();

    nodeEls.forEach(function (ne) {
      let drag = null;
      ne.el.addEventListener("pointerdown", function (e) {
        if (e.button !== 0) return;
        drag = { startX: e.clientX, startY: e.clientY, ox: ne.spec.x, oy: ne.spec.y };
        ne.el.classList.add("pg-node--dragging");
        ne.el.setPointerCapture(e.pointerId);
        e.preventDefault();
      });
      ne.el.addEventListener("pointermove", function (e) {
        if (!drag) return;
        ne.spec.x = Math.max(0, drag.ox + (e.clientX - drag.startX));
        ne.spec.y = Math.max(0, drag.oy + (e.clientY - drag.startY));
        place();
      });
      function end() {
        if (!drag) return;
        drag = null;
        ne.el.classList.remove("pg-node--dragging");
        if (typeof onChange === "function") onChange();
      }
      ne.el.addEventListener("pointerup", end);
      ne.el.addEventListener("pointercancel", end);
    });
  }

  function el(tag, attrs) {
    const node = document.createElementNS(NS, tag);
    if (attrs) {
      for (const k in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, k)) {
          node.setAttribute(k, String(attrs[k]));
        }
      }
    }
    return node;
  }

  function showMessage(svg, text) {
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    const t = el("text", { x: PAD, y: PAD + 14, class: "pg-node-text pg-node-text--sub" });
    t.textContent = text;
    svg.appendChild(t);
    svg.setAttribute("width", 400);
    svg.setAttribute("height", 60);
  }

  function loadSaved(processName) {
    if (!processName) return {};
    try {
      const raw = localStorage.getItem(STORAGE_PREFIX + processName);
      if (!raw) return {};
      return JSON.parse(raw) || {};
    } catch (e) { return {}; }
  }

  function saveLayout(processName, nodes) {
    if (!processName) return;
    const out = {};
    nodes.forEach(function (n) {
      out[n.id] = { x: Math.round(n.x), y: Math.round(n.y) };
    });
    try {
      localStorage.setItem(STORAGE_PREFIX + processName, JSON.stringify(out));
    } catch (e) { /* quota — best effort */ }
  }
})();

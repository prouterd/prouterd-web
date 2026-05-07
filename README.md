# prouterd-web

Operator console for the [prouterd](../prouterd-core) Process Router — a
zero-build static SPA. Open `index.html` in any browser, point it at a
running prouterd-core daemon, and the console talks to it directly over
HTTP `/v1/*` and two WebSockets (`/v1/events` for live state,
`/v1/cli/:session_id` for interactive shell sessions). No build step,
no proxy, no Ruby.

```
Browser  ──HTTP /v1/* (bearer)        ──>  prouterd daemon
         ──WS  /v1/events (subscribe) ──>  SQLite + runners + scheduler
         ──WS  /v1/cli/:sid (shell)   ──>
```

## Quickstart

### 1. Run a prouterd daemon

```sh
cd ../prouterd-core
PROUTERD_ADMIN_TOKEN=demo bundle exec exe/prouterd \
  --db /tmp/prouterd.db --port 9000
```

### 2. Serve the static console

Anything that serves a directory works — `python3`, `npx serve`, nginx,
GitHub Pages, S3:

```sh
python3 -m http.server 8080
```

Open <http://localhost:8080/login.html>, enter the daemon URL
(`http://localhost:9000`) and the bearer token, sign in.

The console stores `{ url, token }` in `sessionStorage` — closing the
tab logs out.

## What core has to provide

The console talks to the daemon directly from the browser, so the
daemon must:

- **Allow CORS on `/v1/*`** for the SPA's origin
  (`Access-Control-Allow-Origin`, `Access-Control-Allow-Headers:
  Authorization, Content-Type`, `Access-Control-Allow-Methods: GET,
  POST, OPTIONS`).
- **Accept the bearer token via a `?token=...` query parameter** on the
  WebSocket endpoints (`/v1/events`, `/v1/cli/:sid`) and on
  `/v1/artifacts/:id/download` so plain `<a download>` links work
  without a custom Authorization header.

Both are stable, well-trodden patterns — they don't change the
daemon's HTTP API surface.

## Layout

```
/
├── index.html              — entry: top-bar / object-tree / workspace
├── login.html              — daemon URL + bearer token entry
└── assets/
    ├── app.css
    ├── core_client.js      — fetch + WS wrapper, bearer from sessionStorage
    ├── adapter.js          — shapes /v1/* JSON into view-model objects
    ├── json_tree.js        — collapsible JSON viewer (used by step / context)
    ├── config_diff.js      — line-oriented LCS diff (used by config / diff)
    ├── ws_client.js        — persistent WS to /v1/events, topic dispatch
    ├── cli_session.js      — per-window WS to /v1/cli/:sid
    ├── window_manager.js   — open / drag / resize / persist windows + actions
    ├── cli.js              — CLI window input + history
    ├── process_graph.js    — Graph tab on Process Inspector (SVG, drag)
    ├── boot.js             — top-bar status pills + logout
    └── windows/
        ├── registry.js
        ├── system.js              processes.js          process_inspector.js
        ├── blocks.js               routes.js             interfaces.js
        ├── queues.js               policies.js           secrets.js
        ├── runs.js                 run_inspector.js      step_inspector.js
        ├── config.js               diff.js
        ├── logs.js                 context.js            artifacts.js
        ├── trace.js                cli.js
```

Each window type is a single async function `render(resourceId) =>
htmlString` registered on `ProuterdWindows`. The window manager calls
the registry; live-update events trigger a debounced re-render.

## Features

- Object tree on the left, draggable / resizable windows in the
  workspace, layout persisted in `localStorage`
- Processes / runs / blocks / routes / interfaces / queues / policies
  / secrets — listings + drill-down inspectors
- **Process Inspector** with a Graph tab — blocks as nodes, routes as
  directed edges, draggable layout per-process
- Run Inspector — per-step status, captured logs, context (with
  redaction performed by the daemon), produced artifacts, replay full
  / from a chosen block
- Step Inspector — input / output JSON trees, per-step logs, per-step
  artifacts
- Config viewer — Active / Boot / Draft / Diff / Commits, with
  rollback and save-as-boot actions
- Trace event — statically walk routes for an event without executing
  blocks
- Embedded CLI window per session, persistent WS to the daemon's
  `/v1/cli/:session_id`
- Live updates over `/v1/events` — windows debounce-refetch on
  relevant topics
- Secret values are never displayed — only declared name and source ref

## Caveats

- **Bearer in `sessionStorage`** — the standard SPA tradeoff. XSS in
  the console code would leak the token. Acceptable for an operator
  tool on a trusted network; for internet-facing deploys, the daemon
  should grow a cookie-session login.
- **Logs window does full re-fetch on tail events** — bandwidth-heavy
  for very chatty runs. An incremental-append path is on the followup
  list.

## License

MIT — see [LICENSE](LICENSE).

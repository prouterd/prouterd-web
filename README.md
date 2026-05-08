# prouterd-web

Operator console for the [prouterd](../prouterd-core) Process Router — a
zero-build static SPA. Open `index.html` in any browser, point it at a
running prouterd-core daemon, and the console talks to it over a single
WebSocket plus one anchor for artifact downloads. No build step, no
proxy, no Ruby.

```
Browser  ──WS  /v1/events  (RPC + live events,  ?token=)  ──>  prouterd daemon
         ──WS  /v1/cli/:sid (interactive shell, ?token=)  ──>  SQLite + runners
         ──HTTP /v1/artifacts/:id/download    (?token=)   ──>  + scheduler
```

The daemon's HTTP `/v1/*` API stays in place for `curl`, automation,
k8s probes, monitoring — the SPA just doesn't use it. Anything the
console needs goes through one RPC envelope on `/v1/events`:

```jsonc
// browser → daemon
{ "id": "msg_42", "type": "call", "payload": { "method": "processes.get", "args": { "name": "lead_pipeline" } } }
// daemon → browser
{ "reply_to": "msg_42", "type": "reply", "payload": { /* same as /v1/processes/:name */ } }
{ "reply_to": "msg_42", "type": "error", "payload": { "code": "not_found", "message": "..." } }
```

The same socket continues to carry the existing
`subscribe`/`unsubscribe`/event frames for live updates.

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

The browser talks to core over WebSocket, with one HTTP anchor for
artifact downloads. Concretely the daemon must:

- **WS-RPC envelope on `/v1/events`** alongside the existing
  `subscribe` / `unsubscribe` / event frames. Two new frame types:
  - in: `{ id, type: "call", payload: { method, args } }`
  - out: `{ reply_to, type: "reply"|"error", payload }`

  Methods mirror the existing `/v1/*` HTTP routes 1:1 (same internal
  services, just dispatched over the socket):

  | method                | what                                    |
  |-----------------------|-----------------------------------------|
  | `status`              | daemon status / drift / queue depth     |
  | `processes.list`      | list processes                          |
  | `processes.get`       | one process w/ blocks + routes          |
  | `processes.trigger`   | fire a one-shot event                   |
  | `interfaces.list`     | declared interfaces                     |
  | `queues.list`         | runner queues                           |
  | `policies.list`       | retry policies                          |
  | `secrets.list`        | declared secrets (no values)            |
  | `runs.list`           | filter by process / status / paginate   |
  | `runs.get`            | one run + its steps                     |
  | `runs.cancel`         | cancel a non-terminal run               |
  | `runs.replay`         | replay (optional `from_block`)          |
  | `runs.resume`         | resume a paused run with `value` (JSON) |
  | `runs.logs`           | per-run logs (optional `step`/`after`)  |
  | `runs.artifacts`      | per-run artifact metadata               |
  | `tools.list`          | top-level `tool <name>` declarations    |
  | `config.running`      | rendered active config text             |
  | `config.startup`      | rendered boot config text               |
  | `config.commits`      | commit history + meta.running/.startup  |
  | `config.commit`       | one commit + rendered_config            |
  | `config.rollback`     | rollback running config to commit       |
  | `config.save_boot`    | promote running → boot                  |
  | `trace`               | static-trace an event                   |

  Error codes the SPA recognises: `not_found`, `bad_request`,
  `unauthorized`, anything else is shown verbatim.

- **`?token=...` query auth** on `/v1/events`, `/v1/cli/:session_id`,
  and `/v1/artifacts/:id/download`. Used as fallback when the
  `Authorization` header is unavailable (WS handshake from the browser,
  plain `<a download>` navigation).

CORS isn't needed: WS handshakes aren't subject to it the same way
fetch is, and the artifact download is plain navigation (no preflight).

## Layout

```
/
├── index.html  login.html  README.md  LICENSE  .gitignore
└── assets/
    ├── core_client.js      session storage + ws/download URL builders
    ├── ws_client.js        persistent WS to /v1/events: pub/sub + RPC call()
    ├── adapter.js          shapes RPC replies into view-model objects
    ├── json_tree.js        collapsible JSON viewer
    ├── config_diff.js      line-oriented LCS diff
    ├── cli_session.js      per-window WS to /v1/cli/:sid
    ├── window_manager.js   open / drag / resize / persist windows + actions
    ├── cli.js              CLI window input + history
    ├── process_graph.js    Graph tab on Process Inspector (SVG, drag)
    ├── boot.js             top-bar status pills + logout
    ├── app.css
    └── windows/            one render(resourceId) per window type
        ├── registry.js
        ├── system.js              processes.js          process_inspector.js
        ├── blocks.js               routes.js             interfaces.js
        ├── queues.js               policies.js           secrets.js
        ├── runs.js                 run_inspector.js      step_inspector.js
        ├── config.js               diff.js
        ├── logs.js                 context.js            artifacts.js
        ├── trace.js                cli.js
```

Each window type registers an `async render(resourceId) => htmlString`
function on `ProuterdWindows`. The window manager calls the registry;
live-update events trigger a debounced re-render.

## Features

- Object tree on the left, draggable / resizable windows in the
  workspace, layout persisted in `localStorage`
- Processes / runs / blocks / routes / interfaces / queues / policies
  / secrets — listings + drill-down inspectors
- **Process Inspector** with a Graph tab — blocks as nodes, routes as
  directed edges, draggable layout per-process
- Run Inspector — per-step status, captured logs, context, produced
  artifacts, replay full / from a chosen block
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
- Secret values are never displayed — only declared name and source
  reference

## Caveats

- **Bearer in `sessionStorage`** — the standard SPA tradeoff. XSS in
  the console code would leak the token. Acceptable for an operator
  tool on a trusted network; for internet-facing deploys, the daemon
  should grow a cookie-session login.
- **Logs window does full re-fetch on tail events** — bandwidth-heavy
  for very chatty runs. An incremental-append path is on the followup
  list.
- **In-flight RPC calls are rejected on WS reconnect.** The reconnect
  itself is automatic and the topic subscription state is restored;
  any call whose reply was lost will be re-issued by the next
  `hydrateBody` / action click.

## License

MIT — see [LICENSE](LICENSE).

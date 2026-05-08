# prouterd-web

Operator console for the [prouterd](../prouterd-core) Process Router — a
zero-build static SPA. Same-origin with the daemon, one WebSocket
for everything live, one anchor for artifact downloads. No build
step, no Ruby.

```
Browser  ──HTTP POST /v1/login  (one bearer check, sets cookie)  ──>  prouterd daemon
         ──WS   /v1/events       (RPC + live events, cookie auth)  ──>  SQLite + runners
         ──WS   /v1/cli/:sid     (interactive shell,   cookie auth) ──>  + scheduler
         ──HTTP /v1/artifacts/:id/download (plain navigation)       ──>
```

The daemon's HTTP `/v1/*` API stays in place for `curl`, automation,
k8s probes, monitoring — the SPA just doesn't use it for anything
beyond login. Console traffic goes through one RPC envelope on
`/v1/events`:

```jsonc
// browser → daemon
{ "id": "msg_42", "type": "call", "payload": { "method": "processes.get", "args": { "name": "lead_pipeline" } } }
// daemon → browser
{ "reply_to": "msg_42", "type": "reply", "payload": { /* same as /v1/processes/:name */ } }
{ "reply_to": "msg_42", "type": "error", "payload": { "code": "not_found", "message": "..." } }
```

The same socket carries the existing `subscribe`/`unsubscribe`/event
frames for live updates.

## Quickstart

The canonical setup is to let the daemon serve the SPA so it's
same-origin with `/v1`. The daemon's `--console-dir` flag does that
in one process — no nginx, no CORS, cookies just work.

```sh
cd ../prouterd-core
PROUTERD_ADMIN_TOKEN=demo bundle exec exe/prouterd \
  --db /tmp/prouterd.db --port 8080 \
  --console-dir ../prouterd-web
```

Open <http://localhost:8080/console/login.html>, enter the bearer
token, sign in. The daemon hands back an HttpOnly cookie session;
the SPA holds nothing sensitive in JS.

For ad-hoc dev without `--console-dir`:

```sh
python3 -m http.server 8080            # in prouterd-web/
```

…but you'll need to put a same-origin reverse proxy in front, or
configure CORS-with-credentials on the daemon. The default no-CORS
setup expects same-origin.

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
  | `runs.resume_by_thread` | resume the most-recently-paused run carrying a thread_id |
  | `runs.logs`           | per-run logs (optional `step`/`after`)  |
  | `runs.artifacts`      | per-run artifact metadata               |
  | `tools.list`          | top-level `tool <name>` declarations    |
  | `mcp.list`            | `interface mcp` declarations + live pool health (state, tools, last error) |
  | `local_repo.status`   | `interface local_repo` auto-pull state per whitelist entry |
  | `config.running`      | rendered active config text             |
  | `config.startup`      | rendered boot config text               |
  | `config.commits`      | commit history + meta.running/.startup  |
  | `config.commit`       | one commit + rendered_config            |
  | `config.rollback`     | rollback running config to commit       |
  | `config.save_boot`    | promote running → boot                  |
  | `trace`               | static-trace an event                   |

  Error codes the SPA recognises: `not_found`, `bad_request`,
  `unauthorized`, anything else is shown verbatim.

- **Cookie session auth.** `POST /v1/login` validates the bearer
  once and sets `prouterd_session=<id>; HttpOnly; SameSite=Lax`.
  Subsequent fetch / WS / `<a download>` traffic rides the cookie
  automatically — the SPA never holds the bearer in JS, so an XSS
  in console code can't leak the credential. `POST /v1/logout`
  revokes the server-side session and clears the cookie.

  Bearer auth (`Authorization: Bearer …` header or `?token=…` query)
  is still accepted on every endpoint for `curl` / k8s probes /
  automation; the SPA just doesn't use it.

- **`--console-dir PATH`** flag on the daemon. Serves the SPA's
  static directory at `/console/*` in the same process. Same-origin
  by construction → cookies attach without CORS plumbing.

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

- **Same-origin assumption.** The cookie-only auth model assumes the
  SPA and the daemon share an origin. The daemon's `--console-dir`
  flag (single-process deploy) and any same-origin reverse proxy
  (nginx / Caddy / Traefik) qualify. A cross-origin SPA would need
  the daemon to ship CORS-with-credentials; not currently configured.
- **In-flight RPC calls are rejected on WS reconnect.** The reconnect
  itself is automatic and the topic subscription state is restored;
  any call whose reply was lost will be re-issued by the next
  `hydrateBody` / action click.

## Tests

```sh
node --test tests/
```

`tests/adapter.test.mjs` runs `assets/adapter.js` inside a `node:vm`
sandbox with stubbed `window.ProuterdWS.call` and exercises the
shaping methods against canned RPC payloads — no browser, no jsdom.
Catches shape regressions (renamed wire field, swapped types,
dropped key) without booting the SPA.

CI runs three checks on every PR (see `.github/workflows/check.yml`):
- `node --check` on every `.js` / `.mjs` (syntax)
- `node --test tests/` (shaping)
- referenced script paths in `index.html` exist (catches asset path
  drift after a rename)

## License

MIT — see [LICENSE](LICENSE).

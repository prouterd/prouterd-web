# prouterd-web

Operator console for the [prouterd](../prouterd) Process Router.

A standalone Ruby web app that talks to a running prouterd daemon over its
`/v1` HTTP API plus two WebSocket streams (`/v1/events` for live state,
`/v1/cli/:session_id` for interactive shell sessions). The console runs
in its own process — no `prouterd` gem dependency at runtime, no shared
SQLite handle, no co-location requirement.

```
Browser  ──HTTP /console + assets──>  prouterd-web (Roda + Puma)
         ──WS /ws (subscribe/cmd)──>            │
                                                │ HTTP /v1/* (bearer)
                                                │ WS  /v1/events (events)
                                                │ WS  /v1/cli/:sid (shell)
                                                ▼
                                       prouterd daemon (Phase 15+)
                                       SQLite + runners + scheduler
```

## Quickstart

### 1. Run an prouterd daemon (any host, port 9000)

```sh
cd ../prouterd
PROUTERD_ADMIN_TOKEN=demo bundle exec exe/prouter serve \
  --db /tmp/prouterd.db --runner stub --port 9000
```

### 2. Run the console

```sh
cd prouterd-ui
bundle install
bundle exec exe/prouterd-web \
  --core-url http://localhost:9000 \
  --core-token demo \
  --admin-token "$(openssl rand -hex 16)" \
  -p 9292
```

Open <http://localhost:9292/console>, sign in with the admin token. The
left object tree opens windows; double-click row entries to drill down.

## Configuration

| Flag                  | Env var                   | What                                                                        |
|-----------------------|---------------------------|-----------------------------------------------------------------------------|
| `--core-url URL`      | `PROUTERD_CORE_URL`        | **Required.** prouterd daemon base URL.                                      |
| `--core-token TOKEN`  | `PROUTERD_CORE_TOKEN`      | Bearer for `/v1` (sent to the daemon).                                      |
| `--admin-token TOKEN` | `PROUTERD_WEB_ADMIN_TOKEN`     | Web-console session token (browser ↔ this app). Empty → auth disabled.     |
| `-p / --port`         |                           | Bind port (default 9292).                                                  |
| `-H / --host`         |                           | Bind host (default 127.0.0.1).                                             |

Console session cookies are HttpOnly, SameSite=Strict, marked Secure when
the request was forwarded over HTTPS.

## Architecture

| Layer                   | What it does                                                            |
|-------------------------|-------------------------------------------------------------------------|
| `CoreClient`            | HTTP wrapper over Net::HTTP. Bearer auth, JSON envelope, typed errors.  |
| `HttpApiAdapter`        | Implements the entire web-side adapter contract over `/v1/*`.           |
| `EventsConsumer`        | Long-lived WS to `/v1/events`. Fans daemon events into `Broadcaster`.   |
| `CliBridge`             | WS to `/v1/cli/:sid` per command. Returns synchronous `{exit_code,…}`.  |
| `Broadcaster`           | In-process pub/sub. Browser WS subscribers fan out from here.           |
| `WebSocketConnection`   | Per-browser WS handler. Forwards subscribes upstream via EventsConsumer.|
| `WindowManager` (JS)    | Drag/resize windows, taskbar, layout persistence in `localStorage`.     |
| `cli.js`                | CLI window: input + history + send `command.exec` over WS.              |

Live updates flow:

```
core orchestrator → core Events bus → core WS /v1/events
        │
        ▼
core's WS server pushes "{topic,type,payload}" frames
        │
        ▼
EventsConsumer (this app) decodes → Broadcaster.publish(topic, payload)
        │
        ▼
WebSocketConnection (per browser) forwards to /ws subscribers
        │
        ▼
Browser's window manager calls hydrateBody() → debounced re-fetch
```

## Acceptance criteria (TZ §46)

20/20 covered:

| # | Item                                              | Status                                        |
|---|---------------------------------------------------|-----------------------------------------------|
| 1 | Запускается без Rails                             | Roda + Puma                                   |
| 2 | Подключается к Process Router Core                | over /v1 HTTP + WS                            |
| 3 | Использует общий CoreAdapter                      | `HttpApiAdapter` (sole adapter post-refactor) |
| 4 | `/console`                                        | ✓                                             |
| 5 | Object tree                                       | ✓                                             |
| 6 | Draggable / resizable windows                     | ✓                                             |
| 7 | Layout persistence                                | localStorage                                  |
| 8 | Список processes                                  | ✓                                             |
| 9 | Список runs                                       | ✓ + pagination                                |
| 10 | Run Inspector                                    | ✓                                             |
| 11 | Steps run                                        | ✓                                             |
| 12 | Logs                                             | ✓ (live tail via WS)                          |
| 13 | Context (with redaction §37.1)                   | ✓                                             |
| 14 | Config (active / boot / draft / diff / commits)  | ✓                                             |
| 15 | WebSocket live updates                           | ✓                                             |
| 16 | Embedded CLI                                     | ✓ via `CliBridge` over WS                     |
| 17 | Trigger process                                  | ✓                                             |
| 18 | Trace event                                      | ✓ via `POST /v1/trace`                        |
| 19 | Replay run (full + from block)                   | ✓                                             |
| 20 | No secret values displayed                       | name + source ref + status only               |

## Tests

```sh
bundle exec rspec
```

177 examples. Adapter + protocol unit specs, integration of the full App
stack against a programmable Rack stub of `/v1` (`spec/support/stub_core_app.rb`).
No daemon required for the suite.

## Caveats

- **Single-worker Puma only.** In cluster mode (`puma -w N`) each worker
  would open its own `EventsConsumer` WS to the daemon and drive its own
  EventMachine reactor; events would be duplicated across browsers depending
  on which worker they hit. Document fix or single-master pattern coming.
- **CSP** not yet in default security headers — `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin` are.
- **CliBridge opens a fresh WS per command.** Adds ~50 ms handshake
  overhead on every Enter; persistent-per-session connection is on the
  followup list.

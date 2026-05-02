require "roda"
require "cgi"
require "digest"
require "faye/websocket"
require "json"
require "rack/utils"
require "time"

module Prouterd
  module Web
    # Roda application serving the Web Console.
    #
    # Bind an adapter via `Prouterd::Web::App.with_adapter(adapter)` — this
    # returns a subclass that holds a reference to the CoreAdapter instance
    # for the lifetime of the process. The unbound App class is never run
    # directly.
    #
    # Auth model (spec §35-37):
    # - When `auth_token` is configured, every request other than /health
    #   and /assets/* must carry a session cookie matching the token's
    #   digest. /login renders a form; POST /login validates and sets the
    #   cookie; WS upgrades check the cookie at handshake time.
    # - When no token is configured, auth is disabled — convenient for
    #   local development and the rspec suite.
    class App < Roda
      WEB_DIR     = __dir__
      COOKIE_NAME = "prouterd_session".freeze

      # Routes that bypass auth: assets, health, and the login flow itself.
      PUBLIC_PATH_PREFIXES = ["/assets/", "/health", "/login", "/logout"].freeze

      # API-style paths get JSON 401 on auth failure; everything else
      # redirects to /login so an HTML browser session can recover.
      API_PATH_PREFIXES = ["/windows/", "/actions/", "/artifacts/", "/ws"].freeze

      plugin :render,
        views:  File.join(WEB_DIR, "views"),
        engine: "erb",
        layout: "layout",
        escape: true
      plugin :public, root: WEB_DIR
      plugin :json
      plugin :halt
      plugin :cookies
      plugin :common_logger if ENV["RACK_ENV"] != "test"

      class << self
        attr_accessor :adapter, :broadcaster, :events_consumer, :cli_bridge, :auth_token_digest

        # Build a configured subclass for an adapter.
        #
        # `events_consumer` (optional): WS /v1/events client. When wired,
        # live events from core fan into our local Broadcaster and out to
        # browser WS subscribers. nil → no live updates.
        #
        # `cli_bridge` (optional): WS /v1/cli/:sid forwarder. When wired,
        # browser command.exec frames go through the bridge to core.
        # nil → falls back to adapter#execute_cli_command (in-process).
        def with_adapter(adapter, auth_token: nil, events_consumer: nil, cli_bridge: nil)
          klass = Class.new(self)
          klass.adapter           = adapter
          klass.broadcaster       = events_consumer&.broadcaster || Broadcaster.new
          klass.events_consumer   = events_consumer
          klass.cli_bridge        = cli_bridge
          klass.auth_token_digest = auth_token && !auth_token.empty? ? digest_token(auth_token) : nil
          klass
        end

        def rack_test_env?
          ENV["RACK_ENV"].to_s.start_with?("test")
        end

        def digest_token(token)
          Digest::SHA256.hexdigest("prouterd-web-v1:#{token}")
        end
      end

      # ----- view helpers (available as instance methods inside templates) -----

      def render_json(value, open_depth: Helpers::JsonTree::DEFAULT_OPEN_DEPTH, redact: true)
        v = redact ? Helpers::Redactor.scrub(value) : value
        Helpers::JsonTree.render(v, open_depth: open_depth)
      end

      def format_log_ts(ts)
        return "" if ts.nil?

        Time.parse(ts.to_s).strftime("%H:%M:%S.%L")
      rescue ArgumentError
        ts.to_s
      end

      def format_bytes(n)
        return "—" if n.nil?
        return "#{n} B"            if n < 1024
        return "#{(n / 1024.0).round(1)} KB" if n < 1024 * 1024

        "#{(n / 1024.0 / 1024.0).round(1)} MB"
      end

      def render_diff(rows)
        return %(<div class="logs__empty">configs are identical</div>) if rows.nil? || rows.all? { |r| r[:action] == "=" }

        out = +%(<div class="diff">)
        rows.each do |row|
          klass =
            case row[:action]
            when "-" then "diff__row diff__row--del"
            when "+" then "diff__row diff__row--ins"
            else          "diff__row diff__row--ctx"
            end
          out << %(<div class="#{klass}">) <<
            %(<span class="diff__no">#{row[:left_no]  || ""}</span>) <<
            %(<span class="diff__no">#{row[:right_no] || ""}</span>) <<
            %(<span class="diff__text">#{CGI.escapeHTML(row[:text].to_s)}</span>) <<
            %(</div>)
        end
        out << %(</div>)
      end

      route do |r|
        apply_security_headers(response)

        # Public assets first — no auth, no logging churn.
        r.public

        adapter = self.class.adapter
        if adapter.nil?
          response.status = 500
          response["Content-Type"] = "text/plain"
          next "Prouterd::Web::App has no adapter configured. " \
               "Use App.with_adapter(adapter) before mounting."
        end

        # /health is unauthenticated by design — uptime checks shouldn't
        # require credentials. It does NOT leak adapter state beyond a
        # version number and a class name (already public-ish info).
        r.get "health" do
          { ok: true, web_version: Prouterd::Web::VERSION, adapter: adapter.class.name }
        end

        # Login flow.
        r.on "login" do
          r.get do
            @login_error = nil
            view "login", layout: false
          end

          r.post do
            token = r.params["token"].to_s
            if auth_enabled? && self.class.digest_token(token) == self.class.auth_token_digest
              set_session_cookie(response, token, r.env)
              r.redirect "/console"
            elsif !auth_enabled?
              r.redirect "/console"
            else
              @login_error = "Invalid token"
              response.status = 401
              view "login", layout: false
            end
          end
        end

        r.post "logout" do
          response.delete_cookie(COOKIE_NAME, path: "/")
          r.redirect "/login"
        end

        # Auth gate for everything below.
        require_auth!(r)

        r.root { r.redirect "/console" }

        r.on "ws" do
          env = r.env
          if Faye::WebSocket.websocket?(env)
            broadcaster = self.class.broadcaster
            if broadcaster.nil?
              response.status = 503
              next "broadcaster not configured"
            end

            ws         = Faye::WebSocket.new(env)
            cli_bridge = self.class.cli_bridge
            cmd_exec   =
              if cli_bridge
                ->(cmd, session_id:) { cli_bridge.dispatch(cmd, session_id: session_id) }
              else
                ->(cmd, session_id:) { adapter.execute_cli_command(cmd, session_id: session_id) }
              end
            conn = WebSocketConnection.new(
              ws,
              broadcaster:      broadcaster,
              command_executor: cmd_exec,
              events_consumer:  self.class.events_consumer
            )
            ws.on(:open)    { conn.on_open }
            ws.on(:message) { |event| conn.on_message(event.data) }
            ws.on(:close)   { conn.on_close }
            r.halt(ws.rack_response)
          else
            response.status = 426
            response["Content-Type"] = "text/plain"
            next "WebSocket upgrade required"
          end
        end

        r.get "console" do
          @adapter = adapter
          @status  = adapter.status
          view "console"
        end

        # Window content fragments. Rendered without the layout and inserted
        # into a window body by the client-side WindowManager.
        r.on "windows" do
          r.get "system" do
            @status = adapter.status
            render "windows/system"
          end

          r.get "processes" do
            @processes = adapter.list_processes
            render "windows/processes"
          end

          r.get "runs" do
            @limit  = clamp_int(r.params["limit"],  default: 50, min: 1, max: 500)
            @offset = clamp_int(r.params["offset"], default: 0,  min: 0, max: 1_000_000)
            @process_filter = r.params["process"].to_s.empty? ? nil : r.params["process"]

            list_args = { limit: @limit, offset: @offset }
            list_args[:process_name] = @process_filter if @process_filter

            @runs  = adapter.list_runs(list_args)
            @total = adapter.count_runs(list_args.reject { |k, _| %i[limit offset].include?(k) })
            render "windows/runs"
          end

          r.get "interfaces" do
            @interfaces = adapter.list_interfaces
            render "windows/interfaces"
          end

          r.get "routes" do
            @routes = adapter.list_routes
            render "windows/routes"
          end

          r.get "blocks" do
            @blocks = adapter.list_blocks
            render "windows/blocks"
          end

          r.get "queues" do
            @queues = adapter.list_queues
            render "windows/queues"
          end

          r.get "policies" do
            @policies = adapter.list_policies
            render "windows/policies"
          end

          r.get "secrets" do
            @secrets = adapter.list_secrets
            render "windows/secrets"
          end

          # Top-level Logs / Artifacts: render a small picker of recent
          # runs. Both data types are run-scoped, so the natural way to
          # reach them from the object tree is "pick a run, then drill in".
          r.get "logs" do
            @runs = adapter.list_runs(limit: 50)
            @kind = "logs"
            render "windows/runs_picker"
          end

          r.get "artifacts" do
            @runs = adapter.list_runs(limit: 50)
            @kind = "artifacts"
            render "windows/runs_picker"
          end

          r.get "process", String do |name|
            @process = adapter.get_process(name)
            if @process.nil?
              response.status = 404
              next %(<div class="window-error">process #{Rack::Utils.escape_html(name)} not found</div>)
            end
            render "windows/process_inspector"
          end

          r.get "run", String do |uid|
            @run = adapter.get_run(uid)
            if @run.nil?
              response.status = 404
              next %(<div class="window-error">run #{Rack::Utils.escape_html(uid)} not found</div>)
            end
            @steps = adapter.get_run_steps(uid)
            render "windows/run_inspector"
          end

          r.get "step", String, String do |run_uid, step_id|
            step = adapter.get_step(run_uid, step_id)
            if step.nil?
              response.status = 404
              next %(<div class="window-error">step #{Rack::Utils.escape_html(step_id)} not found in run #{Rack::Utils.escape_html(run_uid)}</div>)
            end
            @run_uid         = run_uid
            @step            = step
            @step_logs       = adapter.get_step_logs(run_uid, step_id: step_id.to_i)
            @step_artifacts  = adapter.get_run_artifacts(run_uid, step_id: step_id.to_i)
            render "windows/step_inspector"
          end

          r.get "logs", String do |run_uid|
            @run_uid = run_uid
            @step_id = r.params["step"]&.to_i
            limit    = clamp_int(r.params["limit"], default: 1000, min: 1, max: 10_000)
            after_id = r.params["after"]&.to_i
            logs     = adapter.get_step_logs(run_uid, step_id: @step_id, after_id: after_id)
            @logs    = logs.last(limit)
            @truncated = logs.size > @logs.size
            render "windows/logs"
          end

          r.get "context", String do |run_uid|
            ctx = adapter.get_run_context(run_uid)
            if ctx.nil?
              response.status = 404
              next %(<div class="window-error">run #{Rack::Utils.escape_html(run_uid)} not found</div>)
            end
            @run_uid = run_uid
            @ctx     = ctx
            render "windows/context"
          end

          r.get "artifacts", String do |run_uid|
            @run_uid    = run_uid
            @artifacts  = adapter.get_run_artifacts(run_uid)
            render "windows/artifacts"
          end

          r.get "cli", String do |sid|
            @session_id     = sid
            @initial_prompt = adapter.cli_prompt(sid)
            render "windows/cli"
          end

          r.get "trace" do
            render "windows/trace"
          end

          r.get "config" do
            @active   = adapter.active_config
            @boot     = adapter.boot_config
            @commits  = adapter.list_commits
            @drift    = @active && @boot && @active[:commit][:id] != @boot[:commit][:id]
            @diff_rows = if @active && @boot
                           adapter.config_diff(left: @boot[:commit][:id], right: @active[:commit][:id])
                         end
            render "windows/config"
          end

          r.get "diff", String, String do |left, right|
            @left  = adapter.get_commit(left)
            @right = adapter.get_commit(right)
            if @left.nil? || @right.nil?
              response.status = 404
              next %(<div class="window-error">commit not found</div>)
            end
            @diff_rows = adapter.config_diff(left: @left[:id], right: @right[:id])
            render "windows/diff"
          end

          r.get String do |type|
            render "windows/placeholder", locals: { type: type }
          end
        end

        # Write-side actions. Each delegates to the adapter, which in turn
        # routes through the relevant core facade (ConfigStore, Orchestrator)
        # — UI never updates pointers or transitions state directly.
        r.on "actions" do
          r.on "config" do
            r.post "rollback", String do |commit_id|
              result = adapter.rollback_config(commit_id.to_i)
              if result
                { ok: true, active_commit: result[:id] }
              else
                response.status = 400
                { ok: false, error: "rollback failed: commit not found or invalid" }
              end
            end

            r.post "save-boot" do
              result = adapter.save_boot_config
              if result
                { ok: true, boot_commit: result[:id] }
              else
                response.status = 400
                { ok: false, error: "no active config to save" }
              end
            end
          end

          r.post "trace" do
            body = parse_json_body(r)
            event = body["event"] || body["input_event"] || {}
            iface = body["interface_name"] || body["interface"]
            iface = nil if iface.is_a?(String) && iface.empty?
            result = adapter.trace_event(event, interface_name: iface)
            if result.is_a?(Hash) && result[:error]
              response.status = 400
              { ok: false, error: result[:error] }
            else
              { ok: true, data: result }
            end
          end

          r.on "runs" do
            r.post "trigger", String do |process_name|
              body  = parse_json_body(r)
              event = body["input_event"] || body["event"] || {}
              result = adapter.trigger_process(process_name, event)
              if result.is_a?(Hash) && result[:run_uid]
                { ok: true, run_uid: result[:run_uid] }
              else
                response.status = 400
                { ok: false, error: result.is_a?(Hash) ? (result[:error] || "trigger failed") : "trigger failed" }
              end
            end

            r.post "replay", String do |uid|
              body = parse_json_body(r)
              from_block = body["from_block"]
              result = adapter.replay_run(uid, from_block: from_block)
              if result.is_a?(Hash) && result[:run_uid]
                { ok: true, run_uid: result[:run_uid], replay_of: result[:replay_of], from_block: result[:from_block] }
              elsif result.is_a?(Hash) && result[:error]
                response.status = 400
                { ok: false, error: result[:error] }
              else
                response.status = 404
                { ok: false, error: "run not found" }
              end
            end

            r.post "cancel", String do |uid|
              if adapter.cancel_run(uid)
                { ok: true, run_uid: uid }
              else
                response.status = 400
                { ok: false, error: "run not found or already terminal" }
              end
            end
          end
        end

        # Artifact byte transfer. The adapter resolves an id to a host
        # filesystem path which the web process can stream. We never
        # accept paths from the client — only IDs — to keep the surface
        # closed against directory traversal.
        r.on "artifacts" do
          r.get String, "download" do |aid|
            info = adapter.get_artifact(aid.to_i)
            if info.nil? || info[:path].nil? || !File.file?(info[:path])
              response.status = 404
              response["Content-Type"] = "text/plain"
              next "artifact not found"
            end

            response["Content-Type"]        = info[:content_type] || "application/octet-stream"
            response["Content-Length"]      = info[:size_bytes].to_s if info[:size_bytes]
            response["Content-Disposition"] =
              %(attachment; filename="#{info[:name].to_s.gsub(/"/, "")}")
            File.binread(info[:path])
          end
        end
      end

      # ----- request helpers (instance methods, callable from route block) -----

      def apply_security_headers(resp)
        resp["X-Content-Type-Options"] = "nosniff"
        resp["X-Frame-Options"]        = "DENY"
        resp["Referrer-Policy"]        = "same-origin"
        # Strict CSP. UI's JS is event-delegation only (no inline `onclick`),
        # styles live in app.css, the WS connects back to same origin only.
        # `style-src` allows inline because we set a few `style="..."`
        # attributes on dynamically-created window elements.
        resp["Content-Security-Policy"] =
          "default-src 'self'; " \
          "script-src 'self'; " \
          "style-src 'self' 'unsafe-inline'; " \
          "img-src 'self' data:; " \
          "connect-src 'self' ws: wss:; " \
          "frame-ancestors 'none'; " \
          "base-uri 'self'; " \
          "form-action 'self'"
      end

      def auth_enabled?
        !self.class.auth_token_digest.nil?
      end

      def cookie_authed?(env)
        return true unless auth_enabled?

        cookies = Rack::Utils.parse_cookies_header(env["HTTP_COOKIE"] || "")
        cookies[COOKIE_NAME] == self.class.auth_token_digest
      end

      def require_auth!(r)
        return if cookie_authed?(r.env)

        path = r.path
        if PUBLIC_PATH_PREFIXES.any? { |p| path == p.chomp("/") || path.start_with?(p) }
          return
        end

        if API_PATH_PREFIXES.any? { |p| path.start_with?(p) }
          response.status = 401
          response["Content-Type"] = "application/json"
          r.halt response.finish_with_body([JSON.dump(ok: false, error: "auth required")])
        else
          r.redirect "/login"
        end
      end

      def set_session_cookie(resp, token, env)
        resp.set_cookie(COOKIE_NAME, {
          value:     self.class.digest_token(token),
          path:      "/",
          httponly:  true,
          same_site: :strict,
          secure:    env["HTTPS"] == "on" || env["HTTP_X_FORWARDED_PROTO"] == "https"
        })
      end

      def parse_json_body(r)
        raw = r.body.read.to_s
        return {} if raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def clamp_int(value, default:, min:, max:)
        return default if value.nil? || value.to_s.empty?

        n = value.to_i
        n = min if n < min
        n = max if n > max
        n
      end
    end
  end
end

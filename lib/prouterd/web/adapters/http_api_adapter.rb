require "json"

module Prouterd
  module Web
    module Adapters
      # Sole adapter — talks to the prouterd daemon's /v1 HTTP API and
      # shapes responses into the hashes view templates / WindowManager
      # consume. Live event push and CLI command streaming live in
      # EventsConsumer (WS /v1/events) and CliBridge (WS /v1/cli/:sid)
      # respectively; this class handles only the request/response surface.
      class HttpApiAdapter
        attr_reader :client

        def initialize(client:, router_name: nil)
          @client      = client
          @router_name = router_name
          @started_at  = Time.now
        end

        # ----- system -----

        def status
          payload = client.get("/v1/status")
          {
            router:                @router_name || payload["router"] || "prouterd",
            healthy:               payload["accepting"] != false,
            core_version:          payload["version"],
            web_version:           Prouterd::Web::VERSION,
            active_commit:         payload["running_commit"],
            boot_commit:           payload["startup_commit"],
            config_drift:          drift?(payload["running_commit"], payload["startup_commit"]),
            workers:               payload["in_flight"] || 0,
            queue_depth:           safe_int(payload["queued"]),
            failed_runs_last_hour: 0,  # not exposed by /v1 (yet)
            uptime_seconds:        (Time.now - @started_at).to_i,
            db_path:               nil,
            artifact_path:         nil
          }
        rescue Prouterd::Web::CoreClient::Error
          unhealthy_status
        end

        # ----- config / commits -----

        def active_config
          rendered = safe { client.get_text("/v1/config/running") }
          payload  = safe { client.get("/v1/config/commits") }
          running_id = payload && payload.dig("meta", "running")
          return nil unless running_id

          commit = (payload["data"] || []).find { |c| c["id"] == running_id }
          { commit: commit_summary(commit), rendered: rendered }
        end

        def boot_config
          payload = safe { client.get("/v1/config/commits") }
          startup_id = payload && payload.dig("meta", "startup")
          return nil unless startup_id

          rendered = safe { client.get_text("/v1/config/startup") }
          commit = (payload["data"] || []).find { |c| c["id"] == startup_id }
          { commit: commit_summary(commit), rendered: rendered }
        end

        def list_commits(limit: 50)
          (client.get("/v1/config/commits")["data"] || []).first(limit).map { |c| commit_summary(c) }
        end

        def get_commit(id)
          c = client.get("/v1/config/commits/#{id.to_i}")["data"]
          commit_summary(c).merge(rendered: c["rendered_config"])
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        def config_diff(left:, right:)
          l = get_commit(left)
          r = get_commit(right)
          return [] if l.nil? || r.nil?

          Helpers::ConfigDiff.lines(l[:rendered] || "", r[:rendered] || "")
        end

        # ----- config-derived collections -----

        def list_interfaces
          (client.get("/v1/interfaces")["data"] || []).map do |i|
            {
              name:      i["name"],
              kind:      i["type"],
              direction: i["direction"],
              status:    i["shutdown"] ? "disabled" : "enabled",
              # Phase 22+ — core ships a plugin-driven `fields` hash so
              # http/llm/postgres/docker/shell all render with their type-
              # specific config (base-url, model, dsn, image, …) without
              # the web side knowing which keys belong to which type.
              fields:    i["fields"] || {},
              # back-compat: pre-Phase-32 daemons flattened webhook + cron
              # fields onto the top-level summary; the UI window still
              # peeks at these for older daemons.
              path:      i["path"],
              method:    i["method"],
              schedule:  i["schedule"],
              timezone:  i["timezone"]
            }.compact
          end
        end

        def list_queues
          (client.get("/v1/queues")["data"] || []).map do |q|
            { name: q["name"], concurrency: q["concurrency"], timeout_ms: q["timeout_ms"] }
          end
        end

        def list_policies
          (client.get("/v1/policies")["data"] || []).map do |p|
            {
              name:                   p["name"],
              retry_attempts:         p["retry_attempts"],
              retry_backoff:          p["retry_backoff"],
              retry_initial_delay_ms: p["retry_initial_delay_ms"],
              retry_max_delay_ms:     p["retry_max_delay_ms"],
              # Phase 25 retry-when conditions. Pre-Phase-32 daemons
              # don't ship this key — fall back to empty list so the UI
              # renders cleanly against either version.
              retry_when:             Array(p["retry_when"]),
              timeout_ms:             p["timeout_ms"]
            }
          end
        end

        def list_secrets
          (client.get("/v1/secrets")["data"] || []).map do |s|
            {
              name:        s["name"],
              source_type: s["source_type"],
              source_ref:  s["source_ref"],
              used_by:     s["used_by"] || [],
              status:      s["status"]
            }
          end
        end

        # ----- processes -----

        def list_processes
          (client.get("/v1/processes")["data"] || []).map do |p|
            {
              name:         p["name"],
              status:       p["shutdown"] ? "disabled" : "enabled",
              blocks:       p["blocks"],
              routes:       p["routes"],
              queue:        p["queue"],
              last_status:  nil,
              success_rate: nil
            }
          end
        end

        def get_process(name)
          payload = client.get("/v1/processes/#{name}")["data"]
          {
            name:         payload["name"],
            description:  payload["description"],
            status:       payload["shutdown"] ? "disabled" : "enabled",
            queue:        payload["queue"],
            entry_block:  Array(payload["blocks"]).first&.dig("name"),
            last_status:  nil,
            success_rate: nil,
            blocks: Array(payload["blocks"]).map { |b| block_to_hash(b) },
            routes: Array(payload["routes"]).map { |r| process_route_to_hash(r, payload["name"]) }
          }
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        def list_routes(process: nil)
          if process
            p = get_process(process)
            return [] unless p

            return p[:routes]
          end

          # No /v1/routes endpoint on core (yet); flatten across processes.
          list_processes.flat_map { |p| (get_process(p[:name]) || { routes: [] })[:routes] }
        end

        def list_blocks
          # No /v1/blocks; build from per-process detail.
          list_processes.flat_map do |p|
            detail = get_process(p[:name]) || { blocks: [] }
            detail[:blocks].map { |b| b.merge(process: p[:name]) }
          end
        end

        # ----- runs -----

        def list_runs(filters = {})
          query = {}
          query[:process] = filters[:process_name] || filters[:process] if filters[:process_name] || filters[:process]
          query[:status]  = filters[:status] if filters[:status]
          query[:limit]   = filters[:limit]  if filters[:limit]
          query[:offset]  = filters[:offset] if filters[:offset]

          rows = client.get("/v1/runs", query)["data"] || []
          rows.map { |r| run_to_hash(r) }
        end

        def count_runs(filters = {})
          # Until /v1 exposes a count head, fetch with a high limit and count.
          # For typical operator views this remains cheap.
          query = {}
          query[:process] = filters[:process_name] || filters[:process] if filters[:process_name] || filters[:process]
          (client.get("/v1/runs", query.merge(limit: 1000))["data"] || []).size
        end

        def get_run(run_uid)
          r = client.get("/v1/runs/#{run_uid}")["data"]
          base = run_to_hash(r)
          base.merge(
            interface_name: r["interface_name"],
            error_summary:  r["error_summary"],
            replayable:     terminal?(r["status"])
          )
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        def get_run_steps(run_uid)
          r = client.get("/v1/runs/#{run_uid}")["data"]
          Array(r["steps"]).map { |s| step_to_hash(s) }
        rescue Prouterd::Web::CoreClient::NotFound
          []
        end

        def get_step(run_uid, step_id)
          steps = client.get("/v1/runs/#{run_uid}")["data"]["steps"] || []
          step  = steps.find { |s| s["id"] == step_id.to_i }
          return nil unless step

          step_to_hash(step).merge(
            input_json:  parse_json(step["input_json"]),
            output_json: parse_json(step["output_json"])
          )
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        def get_run_context(run_uid)
          r = client.get("/v1/runs/#{run_uid}")["data"]
          {
            input_event: parse_json(r["input_event_json"]),
            context:     parse_json(r["context_json"])
          }
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        def get_step_logs(run_uid, step_id: nil, after_id: nil)
          query = {}
          query[:step]  = step_id  if step_id
          query[:after] = after_id if after_id

          rows = client.get("/v1/runs/#{run_uid}/logs", query)["data"] || []
          rows.map do |l|
            {
              id:         l["id"],
              run_id:     l["run_id"],
              step_id:    l["step_id"],
              stream:     l["stream"],
              content:    l["content"],
              created_at: l["created_at"]
            }
          end
        rescue Prouterd::Web::CoreClient::NotFound
          []
        end

        def get_run_artifacts(run_uid, step_id: nil)
          rows = client.get("/v1/runs/#{run_uid}/artifacts")["data"] || []
          rows = rows.select { |a| a["step_id"] == step_id.to_i } if step_id
          rows.map do |a|
            {
              id:           a["id"],
              step_id:      a["step_id"],
              block_name:   a["block_name"],
              name:         a["name"],
              size_bytes:   a["size_bytes"],
              content_type: a["content_type"],
              checksum:     a["checksum"],
              created_at:   a["created_at"],
              path:         a["path"]
            }
          end
        rescue Prouterd::Web::CoreClient::NotFound
          []
        end

        def get_artifact(id)
          # Returns a "downloadable" descriptor for the App route to stream
          # bytes through. We resolve the metadata first via list, then the
          # actual bytes flow through the App's download endpoint by way of
          # `client.get_bytes`. The web route can either pull bytes here
          # (current single-process deploy) or emit a 302 to the daemon's
          # download URL.
          { id: id.to_i, path: nil, content_type: nil, size_bytes: nil, name: "artifact-#{id}" }
        end

        # ----- run actions -----

        def trigger_process(process_name, input_event)
          payload = client.post("/v1/processes/#{process_name}/trigger", input_event || {})
          uid = payload.dig("data", "run_id")
          uid ? { run_uid: uid } : { error: payload["error"] || "trigger failed" }
        rescue Prouterd::Web::CoreClient::NotFound
          { error: "process '#{process_name}' is not in the active config" }
        rescue Prouterd::Web::CoreClient::Error => e
          { error: e.message }
        end

        def replay_run(run_uid, from_block: nil)
          body = {}
          body[:from_block] = from_block if from_block
          payload = client.post("/v1/runs/#{run_uid}/replay", body)
          new_uid = payload.dig("data", "run_id")
          if new_uid
            { run_uid: new_uid, replay_of: run_uid, from_block: from_block }
          else
            { error: payload["error"] || "replay failed" }
          end
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        rescue Prouterd::Web::CoreClient::Error => e
          { error: e.message }
        end

        def cancel_run(run_uid)
          client.post("/v1/runs/#{run_uid}/cancel")
          true
        rescue Prouterd::Web::CoreClient::Error
          false
        end

        # ----- config actions -----

        def rollback_config(commit_id)
          payload = client.post("/v1/config/rollback", commit_id: commit_id.to_i)
          data = payload["data"]
          return nil unless data

          { id: data["commit_id"], short_checksum: short_checksum(data["checksum"]) }
        rescue Prouterd::Web::CoreClient::NotFound, Prouterd::Web::CoreClient::BadRequest
          nil
        end

        def save_boot_config
          payload = client.post("/v1/config/save-boot")
          data = payload["data"]
          return nil unless data

          { id: data["commit_id"], short_checksum: short_checksum(data["checksum"]) }
        rescue Prouterd::Web::CoreClient::Conflict
          nil
        end

        # ----- trace -----

        def trace_event(event_json, interface_name: nil)
          body = { event: event_json || {} }
          body[:interface] = interface_name if interface_name && !interface_name.empty?
          payload = client.post("/v1/trace", body)
          payload["data"]
        rescue Prouterd::Web::CoreClient::Error => e
          { error: e.message }
        end

        # ----- CLI -----
        #
        # CLI exec doesn't go through this HTTP adapter at all — it's
        # bidirectional streaming, handled by Prouterd::Web::CliBridge over
        # WS /v1/cli/:session_id. The methods are stubbed here so the
        # CoreAdapter contract is satisfied for tests; production wires the
        # CliBridge into WebSocketConnection's command_executor instead.

        def execute_cli_command(command, session_id:)
          { exit_code: 1, stdout: "", stderr: "% CLI is served over WS, not HTTP\n",
            prompt: "prouter# " }
        end

        def cli_prompt(_session_id)
          "prouter# "
        end

        # Streams artifact bytes from core through to the web caller.
        # Returns a hash compatible with the App's /artifacts/:id/download
        # route (which expects { content_type:, size_bytes:, name:, body: }).
        def fetch_artifact_bytes(id)
          resp = client.get_bytes("/v1/artifacts/#{id.to_i}/download")
          {
            content_type: resp[:headers]["content-type"],
            size_bytes:   resp[:headers]["content-length"]&.to_i,
            name:         disposition_filename(resp[:headers]["content-disposition"]) || "artifact-#{id}",
            body:         resp[:body]
          }
        rescue Prouterd::Web::CoreClient::NotFound
          nil
        end

        private

        # ----- shaping helpers -----

        def run_to_hash(r)
          {
            run_uid:       r["uid"],
            process_name:  r["process_name"],
            status:        r["status"],
            duration_ms:   r["duration_ms"],
            started_at:    r["started_at"],
            finished_at:   r["finished_at"],
            config_commit: r["commit_id"],
            trigger:       r["interface_name"],
            replay_of:     r["replay_of_uid"]  # human-friendly uid; daemon
                                               # >= core@880d9d6 surfaces it
                                               # via run_summary's LEFT JOIN.
          }
        end

        def step_to_hash(s)
          {
            id:            s["id"],
            block_name:    s["block_name"],
            status:        s["status"],
            attempt:       s["attempt"],
            # `image` is populated only for docker steps (orchestrator
            # writes iface.type_fields["image"] into the row). For shell /
            # http / llm / postgres it's nil — UI shows "—".
            image:         s["image"],
            exit_code:     s["exit_code"],
            error_type:    s["error_type"],
            error_message: s["error_message"],
            started_at:    s["started_at"],
            finished_at:   s["finished_at"],
            duration_ms:   s["duration_ms"]
          }
        end

        # Phase 23 reshaped the block: `interface_ref` + `call_fields`
        # replaced `image` / `command` / `input` / `output`. This hash
        # mirrors the new shape and adds a single-line `interface_label`
        # ("docker img1") for tabular display.
        def block_to_hash(b)
          iface       = b["interface"] || {}
          call_fields = b["call_fields"] || {}
          {
            name:            b["name"],
            interface_type:  iface["type"],
            interface_name:  iface["name"],
            interface_label: iface["type"] && iface["name"] ? "#{iface['type']} #{iface['name']}" : nil,
            call_fields:     call_fields,
            call_summary:    summarize_call_fields(iface["type"], call_fields),
            timeout_ms:      b["timeout_ms"],
            retry_policy:    b["retry_policy"],
            contract:        b["contract"],
            secret_names:    Array(b["secret_names"]),
            status:          b["shutdown"] ? "disabled" : "ready"
          }
        end

        # Single-line summary of the most operator-relevant per-call args.
        # Per iface type, picks the field that's most likely to identify
        # what the block actually does. Falls back to a generic key=value
        # render so unknown types still render something useful.
        def summarize_call_fields(iface_type, fields)
          return nil if fields.empty?

          case iface_type
          when "shell"    then fields["exec"]
          when "docker"   then fields["command"]
          when "http"     then [fields["method"], fields["path"]].compact.join(" ").strip.then { |s| s.empty? ? nil : s }
          when "llm"      then fields["prompt"]&.then { |p| p.length > 80 ? "#{p[0, 80]}…" : p }
          when "postgres" then fields["query"]&.then { |q| q.length > 80 ? "#{q[0, 80]}…" : q }
          else
            fields.first(2).map { |k, v| "#{k}=#{v}" }.join(" ")
          end
        end

        def process_route_to_hash(r, process_name)
          {
            from:       r["from"],
            to:         r["to"],
            condition:  matches_to_condition(r["matches"]),
            enabled:    r["shutdown"] == false || r["shutdown"].nil?,
            on_failure: r["on_failure"],
            process:    process_name
          }
        end

        def commit_summary(c)
          return nil unless c

          {
            id:             c["id"],
            checksum:       c["checksum"],
            short_checksum: short_checksum(c["checksum"]),
            author:         c["author"],
            message:        c["message"],
            created_at:     c["created_at"]
          }
        end

        def matches_to_condition(matches)
          return nil if matches.nil? || matches.empty?

          matches.map { |m| match_to_string(m) }.join(" AND ")
        end

        def match_to_string(m)
          op   = m["operator"]
          path = m["path"]
          vals = m["values"] || []

          case op
          when "exists" then path
          when "in"     then "#{path} in [#{vals.map { |v| format_value(v) }.join(', ')}]"
          else "#{path} #{op} #{format_value(vals.first)}"
          end
        end

        def format_value(v)
          case v
          when Numeric, TrueClass, FalseClass then v.to_s
          when nil                            then "null"
          else v.inspect
          end
        end

        def parse_json(value)
          return value if value.is_a?(Hash) || value.is_a?(Array)
          return nil   if value.nil? || value.to_s.empty?

          JSON.parse(value)
        rescue JSON::ParserError
          value
        end

        def short_checksum(checksum)
          checksum.to_s.sub(/\Asha256:/, "")[0, 12]
        end

        def disposition_filename(header)
          return nil if header.nil?

          header[/filename="([^"]+)"/, 1]
        end

        def drift?(running_id, startup_id)
          return false if running_id.nil? && startup_id.nil?
          return true  if running_id.nil? ^ startup_id.nil?

          running_id != startup_id
        end

        def terminal?(status)
          %w[success failed canceled].include?(status)
        end

        def safe
          yield
        rescue Prouterd::Web::CoreClient::Error
          nil
        end

        def safe_int(v)
          v.is_a?(Numeric) ? v : 0
        end

        def unhealthy_status
          {
            router:                @router_name || "prouterd",
            healthy:               false,
            core_version:          nil,
            web_version:           Prouterd::Web::VERSION,
            active_commit:         nil,
            boot_commit:           nil,
            config_drift:          false,
            workers:               0,
            queue_depth:           0,
            failed_runs_last_hour: 0,
            uptime_seconds:        (Time.now - @started_at).to_i,
            db_path:               nil,
            artifact_path:         nil
          }
        end
      end
    end
  end
end

require "json"
require "rack"

module Prouterd
  module Web
    module Specs
      # Programmable Rack app that mimics the prouterd daemon's /v1 surface.
      # Each spec configures the slice of state it cares about:
      #
      #   stub = StubCoreApp.new
      #   stub.processes = [{ name: "p", description: nil, queue: "q",
      #                       shutdown: false, blocks: 1, routes: 0 }]
      #   stub.runs["run_42"] = { uid: "run_42", status: "success", ... }
      #
      # The shape of every response matches what the real V1 handler returns:
      # `{ "data": ..., "meta": ... }` on success, `{ "error": "...", ... }`
      # on failure. That keeps the HttpApiAdapter spec'd against a faithful
      # contract even though no live core is running.
      class StubCoreApp
        attr_accessor :status_payload, :processes, :interfaces, :queues,
                      :policies, :secrets, :commits, :running_commit_id,
                      :startup_commit_id, :running_config_text, :startup_config_text,
                      :runs, :run_logs, :run_artifacts, :artifacts_by_id,
                      :artifact_bytes, :trace_payload, :token,
                      :triggered_runs, :replayed_runs, :canceled_runs,
                      :rolled_back, :saved_boot

        def initialize
          @status_payload = {
            "version" => "0.0.0", "router" => "stub",
            "running_commit" => nil, "startup_commit" => nil,
            "interfaces" => 0, "processes" => 0, "accepting" => true
          }
          @processes  = []      # array of process detail hashes
          @interfaces = []
          @queues     = []
          @policies   = []
          @secrets    = []
          @commits    = []      # array of commit hashes
          @running_commit_id    = nil
          @startup_commit_id    = nil
          @running_config_text  = "router stub\nexit\n"
          @startup_config_text  = nil
          @runs            = {}      # uid => run hash (with steps inside)
          @run_logs        = {}      # uid => [log hashes]
          @run_artifacts   = {}      # uid => [artifact hashes]
          @artifacts_by_id = {}      # id  => artifact hash
          @artifact_bytes  = {}      # id  => raw bytes string
          @trace_payload   = nil     # response shape for /v1/trace
          @token           = nil     # bearer required when set

          @triggered_runs  = []      # capture POST /trigger calls
          @replayed_runs   = []      # capture POST /replay calls
          @canceled_runs   = []      # capture POST /cancel calls
          @rolled_back     = []      # capture POST /rollback calls
          @saved_boot      = 0       # POST /save-boot counter
        end

        def call(env)
          request = Rack::Request.new(env)
          path = request.path_info
          method = request.request_method

          return [200, json_headers, [JSON.dump(@status_payload)]] if method == "GET" && path == "/v1/status"

          if @token
            header = env["HTTP_AUTHORIZATION"].to_s
            return json_response(401, error: "missing bearer") unless header.start_with?("Bearer ")
            return json_response(403, error: "wrong token") unless header.sub(/\ABearer\s+/, "") == @token
          end

          dispatch(method, path, request)
        rescue StandardError => e
          json_response(500, error: "stub error: #{e.class}: #{e.message}")
        end

        # ----- dispatch -----

        def dispatch(method, path, request)
          segments = path.split("/").reject(&:empty?)

          case [method, segments]
          when ["GET",  %w[v1 config running]]   then text_response(200, @running_config_text)
          when ["GET",  %w[v1 config startup]]   then @startup_config_text ? text_response(200, @startup_config_text) : json_response(404, error: "no startup")
          when ["GET",  %w[v1 config commits]]   then json_response(200, data: @commits, meta: { running: @running_commit_id, startup: @startup_commit_id })
          when ["POST", %w[v1 config save-boot]] then handle_save_boot
          when ["POST", %w[v1 config rollback]]  then handle_rollback(request)
          when ["GET",  %w[v1 processes]]        then json_response(200, data: @processes.map { |p| process_summary(p) })
          when ["GET",  %w[v1 interfaces]]       then json_response(200, data: @interfaces)
          when ["GET",  %w[v1 queues]]           then json_response(200, data: @queues)
          when ["GET",  %w[v1 policies]]         then json_response(200, data: @policies)
          when ["GET",  %w[v1 secrets]]          then json_response(200, data: @secrets)
          when ["GET",  %w[v1 runs]]             then handle_list_runs(request)
          when ["POST", %w[v1 trace]]            then json_response(200, data: @trace_payload || {})
          else dispatch_dynamic(method, segments, request)
          end
        end

        def dispatch_dynamic(method, segments, request)
          if method == "GET" && segments.length == 4 && segments[0..2] == %w[v1 config commits]
            commit = @commits.find { |c| c[:id].to_i == segments[3].to_i }
            return commit ? json_response(200, data: commit) : json_response(404, error: "no commit")
          end
          if method == "GET" && segments.length == 3 && segments[0..1] == %w[v1 processes]
            p = @processes.find { |x| x[:name] == segments[2] }
            return p ? json_response(200, data: p) : json_response(404, error: "no process")
          end
          if method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 processes] && segments[3] == "trigger"
            return json_response(404, error: "no such process") unless @processes.find { |p| p[:name] == segments[2] }

            @triggered_runs << { name: segments[2], body: parse_json(request) }
            uid = "run_stub_#{@triggered_runs.size}"
            return json_response(202, data: { run_id: uid, status: "queued" })
          end
          if method == "GET" && segments.length == 3 && segments[0..1] == %w[v1 runs]
            r = @runs[segments[2]]
            return r ? json_response(200, data: r) : json_response(404, error: "no run")
          end
          if method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "logs"
            return handle_run_logs(request, segments[2])
          end
          if method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "artifacts"
            arts = @run_artifacts[segments[2]] || []
            return json_response(200, data: arts)
          end
          if method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "replay"
            return handle_replay(request, segments[2])
          end
          if method == "POST" && segments.length == 4 && segments[0..1] == %w[v1 runs] && segments[3] == "cancel"
            return handle_cancel(segments[2])
          end
          if method == "GET" && segments.length == 4 && segments[0..1] == %w[v1 artifacts] && segments[3] == "download"
            return handle_artifact_download(segments[2])
          end

          json_response(404, error: "stub: no route for #{method} #{path_join(segments)}")
        end

        # ----- handlers -----

        def handle_save_boot
          @saved_boot += 1
          if @running_commit_id
            @startup_commit_id = @running_commit_id
            commit = @commits.find { |c| c[:id] == @running_commit_id }
            json_response(200, data: { commit_id: @running_commit_id, checksum: commit ? commit[:checksum] : "stub" })
          else
            json_response(409, error: "no running config")
          end
        end

        def handle_rollback(request)
          body = parse_json(request) || {}
          commit_id = body["commit_id"]
          if commit_id.nil? || !@commits.find { |c| c[:id] == commit_id }
            return json_response(404, error: "no such commit")
          end
          @rolled_back << commit_id
          @running_commit_id = commit_id
          json_response(200, data: { commit_id: commit_id, checksum: @commits.find { |c| c[:id] == commit_id }[:checksum] })
        end

        def handle_list_runs(request)
          process = request.params["process"]
          rows = @runs.values
          rows = rows.select { |r| r[:process_name] == process } if process
          json_response(200, data: rows)
        end

        def handle_run_logs(request, uid)
          logs = @run_logs[uid] || []
          step = request.params["step"]
          logs = logs.select { |l| l[:step_id].to_s == step } if step
          json_response(200, data: logs)
        end

        def handle_replay(request, uid)
          return json_response(404, error: "no run") unless @runs[uid]

          body = parse_json(request) || {}
          @replayed_runs << { uid: uid, from_block: body["from_block"] }
          new_uid = "run_replay_#{@replayed_runs.size}"
          json_response(202, data: { run_id: new_uid, replay_of: uid, from_block: body["from_block"] })
        end

        def handle_cancel(uid)
          run = @runs[uid]
          return json_response(404, error: "no run") unless run
          return json_response(409, error: "already terminal") if %w[success failed canceled].include?(run[:status])

          @canceled_runs << uid
          run[:status] = "canceled"
          json_response(200, data: { run_id: uid, status: "canceled" })
        end

        def handle_artifact_download(id)
          art = @artifacts_by_id[id.to_i]
          return json_response(404, error: "no artifact") unless art

          bytes = @artifact_bytes[id.to_i]
          return json_response(410, error: "bytes missing") unless bytes

          headers = {
            "content-type"        => art[:content_type] || "application/octet-stream",
            "content-length"      => bytes.bytesize.to_s,
            "content-disposition" => %(attachment; filename="#{art[:name]}")
          }
          [200, headers, [bytes]]
        end

        # ----- helpers -----

        def process_summary(p)
          {
            name:        p[:name],
            description: p[:description],
            queue:       p[:queue],
            shutdown:    p[:shutdown],
            blocks:      (p[:blocks].is_a?(Array) ? p[:blocks].size : p[:blocks]),
            routes:      (p[:routes].is_a?(Array) ? p[:routes].size : p[:routes])
          }
        end

        def parse_json(request)
          raw = request.body.read.to_s
          request.body.rewind if request.body.respond_to?(:rewind)
          return {} if raw.empty?

          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        def json_response(status, payload)
          [status, json_headers, [JSON.dump(payload)]]
        end

        def text_response(status, body)
          [status, { "content-type" => "text/plain" }, [body]]
        end

        def json_headers
          { "content-type" => "application/json" }
        end

        def path_join(segments)
          "/" + segments.join("/")
        end
      end
    end
  end
end

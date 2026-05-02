require "prouterd"
require "json"
require "stringio"
require "time"

module Prouterd
  module Web
    module Adapters
      # Wraps a live Prouterd SQLite database. Reads go through core's
      # repository classes and ConfigStore; writes (when implemented in
      # later phases) MUST go through ControlPlane / Runtime facades —
      # never raw SQL — so we don't bypass state machines, validation, or
      # transactions.
      class SqliteAdapter < CoreAdapter
        attr_reader :db_path, :router_name

        def initialize(db_path:, router_name: "prouterd", run_migrations: false, runner: nil)
          @db_path      = db_path
          @router_name  = router_name
          @db           = Prouterd::Storage::DB.open(db_path, run_migrations: run_migrations)
          @config_store = Prouterd::ControlPlane::ConfigStore.new(@db)
          @runs_repo    = Prouterd::Storage::Repositories::Runs.new(@db)
          @runner       = runner || Prouterd::Runner::StubRunner.new
          @started_at   = Time.now
          @cli_sessions = {}
          @cli_sessions_mutex = Mutex.new
        end

        def close
          @db&.close
        end

        # ----- system -----

        def status
          running = safe { @config_store.running_commit }
          startup = safe { @config_store.startup_commit }
          doc     = safe { @config_store.load_running }

          {
            router:                doc&.router&.name || @router_name,
            healthy:               !@db.closed?,
            core_version:          (defined?(Prouterd::VERSION) ? Prouterd::VERSION : "unknown"),
            web_version:           Prouterd::Web::VERSION,
            active_commit:         running&.id,
            boot_commit:           startup&.id,
            config_drift:          drift?(running, startup),
            workers:               0,
            queue_depth:           safe { count_runs_with_status("queued") } || 0,
            failed_runs_last_hour: safe { count_failed_runs_since(Time.now - 3600) } || 0,
            uptime_seconds:        (Time.now - @started_at).to_i,
            db_path:               @db_path,
            artifact_path:         nil
          }
        end

        # ----- config-derived collections -----

        def list_interfaces
          document.interfaces.map do |iface|
            {
              name:   iface.name,
              kind:   iface.type,
              status: iface.shutdown ? "disabled" : "enabled"
            }
          end
        end

        def list_processes
          document.processes.map do |p|
            {
              name:         p.name,
              status:       p.shutdown ? "disabled" : "enabled",
              blocks:       p.blocks.size,
              routes:       p.routes.size,
              queue:        p.queue_name,
              last_status:  safe { last_run_status_for(p.name) },
              success_rate: nil
            }
          end
        end

        def list_blocks
          document.processes.flat_map do |p|
            p.blocks.map { |b| block_to_hash(b).merge(process: p.name) }
          end
        end

        def list_queues
          document.queues.map do |q|
            { name: q.name, concurrency: q.concurrency, timeout_ms: q.timeout_ms }
          end
        end

        def list_policies
          document.policies.map do |p|
            {
              name:                   p.name,
              retry_attempts:         p.retry_attempts,
              retry_backoff:          p.retry_backoff,
              retry_initial_delay_ms: p.retry_initial_delay_ms,
              retry_max_delay_ms:     p.retry_max_delay_ms,
              timeout_ms:             p.timeout_ms
            }
          end
        end

        # Spec §33 / §37.1: secret VALUES are never exposed. We return only
        # the declared name, the source type, and the source ref (e.g. an
        # env var NAME — not its value), plus a "present"/"missing" status
        # for env-backed secrets so an operator can verify configuration
        # without the value itself ever crossing the wire.
        def list_secrets
          doc = document
          used = secret_usage_index(doc)

          doc.secrets.map do |s|
            {
              name:        s.name,
              source_type: s.source_type,
              source_ref:  s.source_value,
              used_by:     used[s.name] || [],
              status:      secret_status(s)
            }
          end
        end

        def list_routes(process: nil)
          doc = document

          if process.nil?
            globals = doc.global_routes.map { |gr| global_route_to_hash(gr) }
            process_routes = doc.processes.flat_map do |p|
              p.routes.map { |r| process_route_to_hash(r, p.name) }
            end
            globals + process_routes
          else
            p = doc.processes.find { |x| x.name == process }
            return [] unless p

            p.routes.map { |r| process_route_to_hash(r, p.name) }
          end
        end

        def get_process(name)
          p = document.processes.find { |x| x.name == name }
          return nil unless p

          {
            name:         p.name,
            description:  p.description,
            status:       p.shutdown ? "disabled" : "enabled",
            queue:        p.queue_name,
            entry_block:  p.blocks.first&.name,
            last_status:  safe { last_run_status_for(p.name) },
            success_rate: nil,
            blocks:       p.blocks.map { |b| block_to_hash(b) },
            routes:       p.routes.map { |r| process_route_to_hash(r, p.name) }
          }
        end

        # ----- runs -----

        def list_runs(filters = {})
          process_name = filters[:process_name] || filters[:process]
          limit  = filters[:limit]  || 50
          offset = filters[:offset] || 0
          status = filters[:status]

          rows = @runs_repo.list_runs(limit: limit, offset: offset, process_name: process_name)
          rows = rows.select { |r| r.status == status } if status
          rows.map { |r| run_to_hash(r) }
        end

        def get_run(run_uid)
          run = @runs_repo.get_run_by_uid(run_uid)
          return nil unless run

          run_to_hash(run).merge(
            interface_name: run.interface_name,
            error_summary:  run.error_summary,
            replayable:     run.terminal?
          )
        end

        def get_run_steps(run_uid)
          run = @runs_repo.get_run_by_uid(run_uid)
          return [] unless run

          @runs_repo.list_steps(run.id).map { |s| step_to_hash(s) }
        end

        def get_step(run_uid, step_id)
          run = @runs_repo.get_run_by_uid(run_uid)
          return nil unless run

          step = @runs_repo.get_step(step_id.to_i)
          return nil unless step && step.run_id == run.id

          step_to_hash(step).merge(
            input_json:  parse_json(step.input_json),
            output_json: parse_json(step.output_json)
          )
        end

        def get_run_context(run_uid)
          run = @runs_repo.get_run_by_uid(run_uid)
          return nil unless run

          {
            input_event: parse_json(run.input_event_json),
            context:     parse_json(run.context_json)
          }
        end

        def get_step_logs(run_uid, step_id: nil, after_id: nil)
          run = @runs_repo.get_run_by_uid(run_uid)
          return [] unless run

          rows = @runs_repo.list_logs(run.id, step_id: step_id&.to_i)
          rows = rows.select { |l| l.id > after_id.to_i } if after_id
          rows.map do |l|
            {
              id:         l.id,
              run_id:     l.run_id,
              step_id:    l.step_id,
              stream:     l.stream,
              content:    l.content,
              created_at: l.created_at
            }
          end
        end

        # ----- config -----

        def active_config
          commit_view(@config_store.running_commit, include_rendered: true)
        end

        def boot_config
          commit_view(@config_store.startup_commit, include_rendered: true)
        end

        def list_commits(limit: 50)
          @config_store.list_commits(limit: limit).map { |c| commit_summary(c) }
        end

        def get_commit(id)
          c = @config_store.get_commit(id.to_i)
          return nil unless c

          commit_summary(c).merge(rendered: c.rendered_config)
        end

        def config_diff(left:, right:)
          l = @config_store.get_commit(left.to_i)
          r = @config_store.get_commit(right.to_i)
          return [] if l.nil? || r.nil?

          Helpers::ConfigDiff.lines(l.rendered_config, r.rendered_config)
        end

        def rollback_config(commit_id)
          c = @config_store.rollback(commit_id.to_i)
          c && commit_summary(c)
        rescue Prouterd::ControlPlane::ConfigStoreError
          nil
        end

        def save_boot_config
          c = @config_store.write_memory
          c && commit_summary(c)
        rescue Prouterd::ControlPlane::ConfigStoreError
          nil
        end

        # ----- shell / CLI -----

        def execute_cli_command(command, session_id:)
          bucket = cli_bucket(session_id)
          out = StringIO.new
          err = StringIO.new
          exit_code = 0

          bucket[:mutex].synchronize do
            shell = Prouterd::Shell::Shell.new(
              session:     bucket[:session],
              input:       StringIO.new,
              output:      out,
              error:       err,
              interactive: false,
              banner:      false
            )
            begin
              exit_code = shell.execute_one(command)
            rescue Prouterd::Shell::ShellError => e
              err.puts "% #{e.message}"
              exit_code = 1
            rescue StandardError => e
              err.puts "% #{e.class}: #{e.message}"
              exit_code = 1
            end
          end

          {
            exit_code: exit_code,
            stdout:    out.string,
            stderr:    err.string,
            prompt:    prompt_for_session(bucket[:session])
          }
        end

        def cli_prompt(session_id)
          prompt_for_session(cli_bucket(session_id)[:session])
        end

        # ----- run actions -----

        def trigger_process(process_name, input_event)
          document = @config_store.load_running
          return { error: "process '#{process_name}' is not in the active config" } \
            unless document.processes.find { |p| p.name == process_name }

          commit = @config_store.running_commit
          run =
            begin
              orchestrator.enqueue(
                document, process_name,
                input_event: input_event || {},
                interface_name: nil,
                commit_id: commit&.id
              )
            rescue Prouterd::Runtime::TriggerError => e
              return { error: e.message }
            end

          spawn_execute(run, document)
          { run_uid: run.uid }
        end

        def cancel_run(run_uid)
          run = @runs_repo.get_run_by_uid(run_uid)
          return false unless run
          return false if %w[success failed canceled].include?(run.status)

          @runs_repo.update_run(
            run.id,
            status:        "canceled",
            finished_at:   Time.now.utc.iso8601(3),
            error_summary: "canceled by operator"
          )
          true
        end

        def replay_run(run_uid, from_block: nil)
          original = @runs_repo.get_run_by_uid(run_uid)
          return nil unless original
          return { error: "run was not pinned to a config commit; cannot replay" } \
            unless original.process_config_commit_id

          commit = @config_store.get_commit(original.process_config_commit_id)
          return { error: "config commit ##{original.process_config_commit_id} no longer exists" } \
            unless commit

          document = Prouterd::Config::Parser.parse(Prouterd::Config::Lexer.tokenize(commit.rendered_config))
          input_event = parse_json(original.input_event_json) || {}

          if from_block
            target = @runs_repo.list_steps(original.id).find { |s| s.block_name == from_block }
            return { error: "block '#{from_block}' did not run; cannot replay from it" } unless target
            return { error: "step '#{from_block}' has no captured input" } unless target.input_json

            payload    = JSON.parse(target.input_json)
            seed       = payload["context"] || {}
            seed_event = seed["event"] || input_event

            new_run = orchestrator.enqueue(
              document, original.process_name,
              input_event:      seed_event,
              interface_name:   original.interface_name,
              commit_id:        original.process_config_commit_id,
              replay_of_run_id: original.id
            )
            spawn_execute(new_run, document, from_block: from_block, seed_context: seed)
          else
            new_run = orchestrator.enqueue(
              document, original.process_name,
              input_event:      input_event,
              interface_name:   original.interface_name,
              commit_id:        original.process_config_commit_id,
              replay_of_run_id: original.id
            )
            spawn_execute(new_run, document)
          end

          { run_uid: new_run.uid, replay_of: original.uid, from_block: from_block }
        rescue Prouterd::Runtime::TriggerError => e
          { error: e.message }
        end

        def get_artifact(id)
          row = @db.query_row(
            "SELECT id, name, path, content_type, size_bytes FROM artifacts WHERE id = ?",
            [id.to_i]
          )
          return nil unless row

          { id: row[0], name: row[1], path: row[2], content_type: row[3], size_bytes: row[4] }
        end

        def get_run_artifacts(run_uid, step_id: nil)
          run = @runs_repo.get_run_by_uid(run_uid)
          return [] unless run

          @runs_repo.list_artifacts(run.id, step_id: step_id&.to_i).map do |a|
            {
              id:           a.id,
              step_id:      a.step_id,
              block_name:   a.block_name,
              name:         a.name,
              size_bytes:   a.size_bytes,
              content_type: a.content_type,
              checksum:     a.checksum,
              created_at:   a.created_at,
              path:         a.path
            }
          end
        end

        private

        def parse_json(text)
          return nil if text.nil? || text.empty?

          JSON.parse(text)
        rescue JSON::ParserError
          text
        end

        def secret_usage_index(doc)
          idx = Hash.new { |h, k| h[k] = [] }
          doc.processes.each do |p|
            p.blocks.each do |b|
              Array(b.secret_names).each { |n| idx[n] << "block #{b.name}" }
            end
          end
          doc.interfaces.each do |iface|
            if iface.respond_to?(:auth) && iface.auth && iface.auth.secret_name
              idx[iface.auth.secret_name] << "interface #{iface.name}"
            end
          end
          idx
        end

        def secret_status(secret)
          case secret.source_type
          when "env"
            ENV.key?(secret.source_value.to_s) ? "present" : "missing"
          else
            "unknown"
          end
        end

        def commit_view(commit, include_rendered: false)
          return nil unless commit

          { commit: commit_summary(commit), rendered: include_rendered ? commit.rendered_config : nil }
        end

        def orchestrator
          @orchestrator ||= Prouterd::Runtime::Orchestrator.new(db: @db, runner: @runner)
        end

        def spawn_execute(run, document, **opts)
          Thread.new do
            Thread.current.name = "exec-#{run.uid}" if Thread.current.respond_to?(:name=)
            begin
              orchestrator.execute_run(run, document, **opts)
            rescue StandardError => e
              warn "[exec] run #{run.uid} failed: #{e.class}: #{e.message}"
            end
          end
        end

        def cli_bucket(session_id)
          @cli_sessions_mutex.synchronize do
            @cli_sessions[session_id] ||= {
              session: build_cli_session,
              mutex:   Mutex.new
            }
          end
        end

        def build_cli_session
          s = Prouterd::Shell::Session.new(store: @config_store)
          s.mode_stack << Prouterd::Shell::Modes::Privileged.new
          s
        end

        def prompt_for_session(session)
          mode = session.mode_stack.last
          suffix = mode.respond_to?(:prompt_suffix) ? mode.prompt_suffix : "#"
          "#{session.hostname}#{suffix} "
        end

        def commit_summary(commit)
          {
            id:             commit.id,
            author:         commit.author,
            message:        commit.message,
            checksum:       commit.checksum,
            short_checksum: commit.short_checksum,
            created_at:     commit.created_at
          }
        end

        # ----- internals -----

        def document
          @config_store.load_running
        end

        def drift?(running, startup)
          return false if running.nil? && startup.nil?
          return true  if running.nil? ^ startup.nil?

          running.id != startup.id
        end

        def count_runs_with_status(status)
          row = @db.query_row("SELECT COUNT(*) FROM runs WHERE status = ?", [status])
          row ? row.first.to_i : 0
        end

        def count_failed_runs_since(time)
          cutoff = time.utc.iso8601(3)
          row = @db.query_row(
            "SELECT COUNT(*) FROM runs WHERE status = 'failed' AND finished_at IS NOT NULL AND finished_at > ?",
            [cutoff]
          )
          row ? row.first.to_i : 0
        end

        def last_run_status_for(process_name)
          row = @runs_repo.list_runs(limit: 1, process_name: process_name).first
          row&.status
        end

        def run_to_hash(run)
          {
            run_uid:       run.uid,
            process_name:  run.process_name,
            status:        run.status,
            duration_ms:   run.duration_ms,
            started_at:    run.started_at,
            finished_at:   run.finished_at,
            config_commit: run.process_config_commit_id,
            trigger:       run.interface_name,
            replay_of:     replay_uid_for(run.replay_of_run_id)
          }
        end

        def replay_uid_for(internal_id)
          return nil if internal_id.nil?

          @runs_repo.get_run(internal_id)&.uid
        end

        def block_to_hash(b)
          {
            name:         b.name,
            image:        b.image,
            timeout_ms:   b.timeout_ms,
            input:        b.input,
            output:       b.output,
            retry_policy: b.retry_policy_name,
            secrets:      Array(b.secret_names),
            network:      b.network,
            status:       b.shutdown ? "disabled" : "ready"
          }
        end

        def step_to_hash(s)
          {
            id:            s.id,
            block_name:    s.block_name,
            status:        s.status,
            attempt:       s.attempt,
            image:         s.image,
            exit_code:     s.exit_code,
            error_type:    s.error_type,
            error_message: s.error_message,
            started_at:    s.started_at,
            finished_at:   s.finished_at,
            duration_ms:   s.duration_ms
          }
        end

        def global_route_to_hash(gr)
          {
            from:      "@interface:#{gr.interface_name}",
            to:        gr.process_name,
            condition: matches_to_condition(gr.matches),
            enabled:   true
          }
        end

        def process_route_to_hash(pr, process_name)
          {
            from:       pr.from_block,
            to:         pr.to_block,
            condition:  matches_to_condition(pr.matches),
            enabled:    !pr.shutdown,
            process:    process_name,
            on_failure: pr.on_failure
          }
        end

        def matches_to_condition(matches)
          return nil if matches.nil? || matches.empty?

          matches.map { |m| match_to_string(m) }.join(" AND ")
        end

        def match_to_string(m)
          case m.operator
          when "exists"
            m.path
          when "in"
            "#{m.path} in [#{m.values.map { |v| format_value(v) }.join(", ")}]"
          else
            "#{m.path} #{m.operator} #{format_value(m.values.first)}"
          end
        end

        def format_value(v)
          case v
          when Numeric, TrueClass, FalseClass then v.to_s
          when nil                            then "null"
          else v.inspect
          end
        end

        # Swallow read errors (e.g. table missing on a freshly created DB)
        # so /console can still render. Healthy-flag in later iterations
        # will report this surface.
        def safe
          yield
        rescue StandardError
          nil
        end
      end
    end
  end
end

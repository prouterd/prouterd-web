require "stringio"

module Prouterd
  module Web
    module Adapters
      # In-memory adapter returning fixture data shaped like what the real
      # SqliteAdapter produces. Lets the UI team work without a populated
      # core database.
      class MockAdapter < CoreAdapter
        def initialize
          @started_at        = Time.now
          @active_commit_id  = 42
          @boot_commit_id    = 39
          @cli_sessions      = {}
          @cli_sessions_mutex = Mutex.new
          @runtime_mutex     = Mutex.new
          @runtime_runs      = {}    # uid → run hash (mutable; used by trigger/replay/cancel)
          @next_run_seq      = 18_500
        end

        def status
          {
            router:                "sales_ops",
            healthy:               true,
            core_version:          (defined?(Prouterd::VERSION) ? Prouterd::VERSION : "0.0.0"),
            web_version:           Prouterd::Web::VERSION,
            active_commit:         @active_commit_id,
            boot_commit:           @boot_commit_id,
            config_drift:          @active_commit_id != @boot_commit_id,
            workers:               2,
            queue_depth:           7,
            failed_runs_last_hour: 3,
            uptime_seconds:        (Time.now - @started_at).to_i,
            db_path:               "(mock)",
            artifact_path:         "(mock)"
          }
        end

        def list_processes
          PROCESSES.values.map do |p|
            {
              name:         p[:name],
              status:       p[:status],
              blocks:       p[:blocks].size,
              routes:       p[:routes].size,
              queue:        p[:queue],
              last_status:  p[:last_status],
              success_rate: p[:success_rate]
            }
          end
        end

        def get_process(name)
          PROCESSES[name]
        end

        def list_interfaces
          [
            { name: "leads_in",     kind: "webhook", status: "enabled"  },
            { name: "billing_evt",  kind: "queue",   status: "enabled"  },
            { name: "support_chat", kind: "webhook", status: "disabled" }
          ]
        end

        def list_routes(process: nil)
          if process.nil?
            PROCESSES.values.flat_map { |p| p[:routes] }
          else
            (PROCESSES[process] || { routes: [] })[:routes]
          end
        end

        def list_blocks
          PROCESSES.values.flat_map do |p|
            p[:blocks].map { |b| b.merge(process: p[:name]) }
          end
        end

        def list_queues
          [
            { name: "default", concurrency: 10, timeout_ms: 600_000 },
            { name: "high",    concurrency:  4, timeout_ms: 300_000 }
          ]
        end

        def list_policies
          [
            { name: "retry_standard",   retry_attempts: 3, retry_backoff: "exponential", retry_initial_delay_ms:  5_000, retry_max_delay_ms: 120_000, timeout_ms: nil },
            { name: "retry_aggressive", retry_attempts: 5, retry_backoff: "linear",      retry_initial_delay_ms:  1_000, retry_max_delay_ms:  30_000, timeout_ms: nil }
          ]
        end

        def list_secrets
          [
            { name: "WEBHOOK_TOKEN",    source_type: "env", source_ref: "WEBHOOK_TOKEN",    used_by: ["leads_in"],     status: "present" },
            { name: "CLEARBIT_API_KEY", source_type: "env", source_ref: "CLEARBIT_API_KEY", used_by: ["enrich"],       status: "missing" },
            { name: "STRIPE_API_KEY",   source_type: "env", source_ref: "STRIPE_API_KEY",   used_by: %w[fetch_invoice retry_charge], status: "missing" }
          ]
        end

        def list_runs(filters = {})
          rows = all_runs.values
          if (proc_name = filters[:process_name] || filters[:process])
            rows = rows.select { |r| r[:process_name] == proc_name }
          end
          if (status = filters[:status])
            rows = rows.select { |r| r[:status] == status }
          end
          rows.sort_by { |r| -(r[:run_uid].sub(/\Arun_/, "").to_i(16) rescue 0) }
              .map { |r| run_summary(r) }
        end

        def get_run(run_uid)
          r = all_runs[run_uid]
          r && run_detail(r)
        end

        def get_run_steps(run_uid)
          all_runs.dig(run_uid, :steps) || []
        end

        def get_step(run_uid, step_id)
          step = RUNS.dig(run_uid, :steps)&.find { |s| s[:id] == step_id.to_i }
          return nil unless step

          step.merge(
            input_json:  STEP_PAYLOADS.dig(step[:id], :input),
            output_json: STEP_PAYLOADS.dig(step[:id], :output)
          )
        end

        def get_run_context(run_uid)
          CONTEXTS[run_uid]
        end

        def get_step_logs(run_uid, step_id: nil, after_id: nil)
          logs = LOGS[run_uid] || []
          logs = logs.select { |l| l[:step_id] == step_id.to_i } if step_id
          logs = logs.select { |l| l[:id] > after_id }           if after_id
          logs
        end

        def get_run_artifacts(run_uid, step_id: nil)
          artifacts = ARTIFACTS[run_uid] || []
          artifacts = artifacts.select { |a| a[:step_id] == step_id.to_i } if step_id
          artifacts
        end

        # ----- config -----

        def active_config
          commit_view(@active_commit_id, include_rendered: true)
        end

        def boot_config
          commit_view(@boot_commit_id, include_rendered: true)
        end

        def list_commits
          COMMITS.map { |c| commit_summary(c) }
        end

        def get_commit(id)
          c = COMMITS_BY_ID[id.to_i]
          return nil unless c

          commit_summary(c).merge(rendered: c[:rendered])
        end

        def config_diff(left:, right:)
          l = COMMITS_BY_ID[left.to_i]
          r = COMMITS_BY_ID[right.to_i]
          return [] if l.nil? || r.nil?

          Helpers::ConfigDiff.lines(l[:rendered], r[:rendered])
        end

        def rollback_config(commit_id)
          c = COMMITS_BY_ID[commit_id.to_i]
          return nil unless c

          @active_commit_id = c[:id]
          commit_summary(c)
        end

        def save_boot_config
          c = COMMITS_BY_ID[@active_commit_id]
          return nil unless c

          @boot_commit_id = @active_commit_id
          commit_summary(c)
        end

        # ----- shell / CLI -----
        #
        # The mock has no ConfigStore, so DB-bound commands (commit, replay,
        # rollback…) will return "% no DB attached" via the real shell. Read
        # commands like `show running-config` work and return whatever the
        # session's running_config holds (empty Document by default).

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
        #
        # The mock has no orchestrator; we synthesize a believable run lifecycle
        # ourselves. trigger/replay create a "running" run that auto-progresses
        # to "success" after a short delay (so the poller emits real events
        # and the operator sees the same progression they would in production).

        def trigger_process(process_name, input_event)
          process = PROCESSES[process_name]
          return { error: "process '#{process_name}' is not in the active config" } unless process

          run = synthesize_run(
            process_name:    process_name,
            interface_name:  nil,
            trigger:         "manual",
            input_event:     input_event || {},
            blocks:          process[:blocks],
            replay_of:       nil
          )
          { run_uid: run[:run_uid] }
        end

        def replay_run(run_uid, from_block: nil)
          original = all_runs[run_uid]
          return nil unless original

          process = PROCESSES[original[:process_name]]
          return { error: "process '#{original[:process_name]}' is not configured" } unless process

          if from_block
            unless process[:blocks].any? { |b| b[:name] == from_block }
              return { error: "block '#{from_block}' is not in process" }
            end
          end

          new_run = synthesize_run(
            process_name:    original[:process_name],
            interface_name:  original[:interface_name],
            trigger:         "replay",
            input_event:     {},
            blocks:          process[:blocks],
            replay_of:       run_uid,
            from_block:      from_block
          )
          { run_uid: new_run[:run_uid], replay_of: run_uid, from_block: from_block }
        end

        def cancel_run(run_uid)
          @runtime_mutex.synchronize do
            r = @runtime_runs[run_uid]
            return false unless r
            return false if %w[success failed canceled].include?(r[:status])

            r[:status]        = "canceled"
            r[:finished_at]   = Time.now.utc.iso8601(3)
            r[:error_summary] = "canceled by operator"
            true
          end
        end

        # Mock has no real artifact bytes — UI gets a 404 from the download
        # endpoint and falls back to "preview only" affordance.
        def get_artifact(_id)
          nil
        end

        private

        def all_runs
          @runtime_mutex.synchronize { RUNS.merge(@runtime_runs) }
        end

        def synthesize_run(process_name:, interface_name:, trigger:, input_event:, blocks:, replay_of:, from_block: nil)
          uid = generate_run_uid
          started_at = Time.now.utc.iso8601(3)

          start_idx = from_block ? blocks.index { |b| b[:name] == from_block } || 0 : 0
          run_blocks = blocks[start_idx..]

          run = {
            run_uid:        uid,
            process_name:   process_name,
            status:         "running",
            started_at:     started_at,
            finished_at:    nil,
            duration_ms:    nil,
            config_commit:  @active_commit_id,
            trigger:        trigger,
            interface_name: interface_name,
            replay_of:      replay_of,
            replayable:     false,
            error_summary:  nil,
            steps:          run_blocks.each_with_index.map do |b, i|
              {
                id:            (Time.now.to_f * 1000).to_i + i,
                block_name:    b[:name],
                status:        "pending",
                attempt:       1,
                image:         b[:image],
                exit_code:     nil,
                error_type:    nil,
                error_message: nil,
                duration_ms:   nil,
                started_at:    nil,
                finished_at:   nil
              }
            end
          }

          @runtime_mutex.synchronize { @runtime_runs[uid] = run }
          schedule_progression(uid)
          run
        end

        def schedule_progression(uid)
          Thread.new do
            Thread.current.name = "mock-progress-#{uid}" if Thread.current.respond_to?(:name=)
            run = @runtime_mutex.synchronize { @runtime_runs[uid] }
            return unless run

            run[:steps].each do |step|
              break if @runtime_mutex.synchronize { @runtime_runs[uid][:status] } == "canceled"

              sleep 0.4
              @runtime_mutex.synchronize do
                next if @runtime_runs[uid][:status] == "canceled"

                step[:status]      = "running"
                step[:started_at]  = Time.now.utc.iso8601(3)
              end

              sleep 0.6
              @runtime_mutex.synchronize do
                next if @runtime_runs[uid][:status] == "canceled"

                step[:status]      = "success"
                step[:finished_at] = Time.now.utc.iso8601(3)
                step[:exit_code]   = 0
                step[:duration_ms] = 600
              end
            end

            @runtime_mutex.synchronize do
              r = @runtime_runs[uid]
              next unless r
              next if r[:status] == "canceled"

              r[:status]      = "success"
              r[:finished_at] = Time.now.utc.iso8601(3)
              r[:replayable]  = true
            end
          rescue StandardError => e
            warn "[mock] progression failed for #{uid}: #{e.class}: #{e.message}"
          end
        end

        def generate_run_uid
          @runtime_mutex.synchronize do
            @next_run_seq += 1
            "run_#{@next_run_seq}"
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
          s = Prouterd::Shell::Session.new(store: nil)
          s.mode_stack << Prouterd::Shell::Modes::Privileged.new
          s
        end

        def prompt_for_session(session)
          mode = session.mode_stack.last
          suffix = mode.respond_to?(:prompt_suffix) ? mode.prompt_suffix : "#"
          "#{session.hostname}#{suffix} "
        end


        def commit_view(id, include_rendered: false)
          c = COMMITS_BY_ID[id]
          return nil unless c

          { commit: commit_summary(c), rendered: include_rendered ? c[:rendered] : nil }
        end

        def commit_summary(c)
          {
            id:             c[:id],
            author:         c[:author],
            message:        c[:message],
            checksum:       c[:checksum],
            short_checksum: short_checksum(c[:checksum]),
            created_at:     c[:created_at]
          }
        end

        def short_checksum(checksum)
          checksum.to_s.sub(/\Asha256:/, "")[0, 12]
        end

        def run_summary(r)
          {
            run_uid:       r[:run_uid],
            process_name:  r[:process_name],
            status:        r[:status],
            duration_ms:   r[:duration_ms],
            started_at:    r[:started_at],
            finished_at:   r[:finished_at],
            config_commit: r[:config_commit],
            trigger:       r[:trigger],
            replay_of:     r[:replay_of]
          }
        end

        def run_detail(r)
          run_summary(r).merge(
            interface_name: r[:interface_name],
            error_summary:  r[:error_summary],
            replayable:     r[:replayable]
          )
        end

        # ----- fixtures -----

        PROCESSES = {
          "lead_pipeline" => {
            name:         "lead_pipeline",
            description:  "Lead enrichment and sales notification",
            status:       "enabled",
            queue:        "default",
            entry_block:  "extract",
            last_status:  "success",
            success_rate: 0.984,
            blocks: [
              { name: "extract",      image: "registry.local/blocks/extract-lead:v1", timeout_ms: 30_000,  input: "event.body",    output: "lead.raw",            retry_policy: nil,              secrets: [],                   network: "on", status: "ready" },
              { name: "enrich",       image: "registry.local/blocks/enrich-lead:v3",  timeout_ms: 120_000, input: "lead.raw",      output: "lead.enriched",       retry_policy: "retry_standard", secrets: ["CLEARBIT_API_KEY"], network: "on", status: "ready" },
              { name: "score",        image: "registry.local/blocks/score-lead:v2",   timeout_ms: 20_000,  input: "lead.enriched", output: "lead.scored",         retry_policy: nil,              secrets: [],                   network: "on", status: "ready" },
              { name: "notify_sales", image: "registry.local/blocks/notify-sales:v1", timeout_ms: 15_000,  input: "lead.scored",   output: "notification.result", retry_policy: nil,              secrets: [],                   network: "on", status: "ready" }
            ],
            routes: [
              { from: "@interface:leads_in", to: "lead_pipeline", condition: 'event.type eq "lead.created"', enabled: true, on_failure: nil,    process: nil              },
              { from: "extract",             to: "enrich",        condition: nil,                            enabled: true, on_failure: "stop", process: "lead_pipeline"  },
              { from: "enrich",              to: "score",         condition: nil,                            enabled: true, on_failure: "stop", process: "lead_pipeline"  },
              { from: "score",               to: "notify_sales",  condition: 'lead.scored.score gt 70',      enabled: true, on_failure: "stop", process: "lead_pipeline"  }
            ]
          },
          "billing_recover" => {
            name:         "billing_recover",
            description:  "Recover failed billing webhooks",
            status:       "enabled",
            queue:        "high",
            entry_block:  "fetch_invoice",
            last_status:  "failed",
            success_rate: 0.912,
            blocks: [
              { name: "fetch_invoice", image: "registry.local/blocks/fetch-invoice:v2", timeout_ms: 30_000, input: "event.body",  output: "invoice", retry_policy: "retry_standard",   secrets: ["STRIPE_API_KEY"], network: "on", status: "ready" },
              { name: "retry_charge",  image: "registry.local/blocks/retry-charge:v4",  timeout_ms: 60_000, input: "invoice",     output: "charge",  retry_policy: "retry_aggressive", secrets: ["STRIPE_API_KEY"], network: "on", status: "ready" }
            ],
            routes: [
              { from: "@interface:billing_evt", to: "billing_recover", condition: 'event.type eq "charge.failed"', enabled: true, on_failure: nil,    process: nil               },
              { from: "fetch_invoice",          to: "retry_charge",    condition: nil,                              enabled: true, on_failure: "stop", process: "billing_recover" }
            ]
          },
          "ticket_triage" => {
            name:         "ticket_triage",
            description:  "Categorize support tickets",
            status:       "disabled",
            queue:        "default",
            entry_block:  "classify",
            last_status:  nil,
            success_rate: nil,
            blocks: [
              { name: "classify", image: "registry.local/blocks/classify:v1", timeout_ms: 20_000, input: "event.body", output: "ticket.category", retry_policy: nil, secrets: [], network: "on", status: "ready" }
            ],
            routes: [
              { from: "@interface:support_chat", to: "ticket_triage", condition: nil, enabled: false, on_failure: nil, process: nil }
            ]
          }
        }.freeze

        RUNS = {
          "run_18492" => {
            run_uid:        "run_18492",
            process_name:   "lead_pipeline",
            status:         "failed",
            started_at:     "2026-05-02T14:12:44Z",
            finished_at:    "2026-05-02T14:13:02Z",
            duration_ms:    18_200,
            config_commit:  42,
            trigger:        "webhook",
            interface_name: "leads_in",
            replay_of:      nil,
            replayable:     true,
            error_summary:  "block notify_sales failed: invalid_output",
            steps: [
              { id: 1, block_name: "extract",      status: "success", attempt: 1, image: "registry.local/blocks/extract-lead:v1", duration_ms: 1_200,  exit_code: 0, error_type: nil,             error_message: nil,                       started_at: "2026-05-02T14:12:44Z", finished_at: "2026-05-02T14:12:45Z" },
              { id: 2, block_name: "enrich",       status: "success", attempt: 1, image: "registry.local/blocks/enrich-lead:v3",  duration_ms: 4_800,  exit_code: 0, error_type: nil,             error_message: nil,                       started_at: "2026-05-02T14:12:45Z", finished_at: "2026-05-02T14:12:50Z" },
              { id: 3, block_name: "score",        status: "success", attempt: 1, image: "registry.local/blocks/score-lead:v2",   duration_ms: 700,    exit_code: 0, error_type: nil,             error_message: nil,                       started_at: "2026-05-02T14:12:50Z", finished_at: "2026-05-02T14:12:50Z" },
              { id: 4, block_name: "notify_sales", status: "failed",  attempt: 1, image: "registry.local/blocks/notify-sales:v1", duration_ms: 12_000, exit_code: 1, error_type: "invalid_output", error_message: "expected JSON object",    started_at: "2026-05-02T14:12:50Z", finished_at: "2026-05-02T14:13:02Z" }
            ]
          },
          "run_18491" => {
            run_uid:        "run_18491",
            process_name:   "lead_pipeline",
            status:         "success",
            started_at:     "2026-05-02T14:09:11Z",
            finished_at:    "2026-05-02T14:09:18Z",
            duration_ms:    6_800,
            config_commit:  42,
            trigger:        "webhook",
            interface_name: "leads_in",
            replay_of:      nil,
            replayable:     true,
            error_summary:  nil,
            steps: [
              { id: 5, block_name: "extract",      status: "success", attempt: 1, image: "registry.local/blocks/extract-lead:v1", duration_ms: 1_100, exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:09:11Z", finished_at: "2026-05-02T14:09:12Z" },
              { id: 6, block_name: "enrich",       status: "success", attempt: 1, image: "registry.local/blocks/enrich-lead:v3",  duration_ms: 3_900, exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:09:12Z", finished_at: "2026-05-02T14:09:16Z" },
              { id: 7, block_name: "score",        status: "success", attempt: 1, image: "registry.local/blocks/score-lead:v2",   duration_ms: 600,   exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:09:16Z", finished_at: "2026-05-02T14:09:17Z" },
              { id: 8, block_name: "notify_sales", status: "success", attempt: 1, image: "registry.local/blocks/notify-sales:v1", duration_ms: 1_200, exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:09:17Z", finished_at: "2026-05-02T14:09:18Z" }
            ]
          },
          "run_18490" => {
            run_uid:        "run_18490",
            process_name:   "billing_recover",
            status:         "success",
            started_at:     "2026-05-02T14:02:33Z",
            finished_at:    "2026-05-02T14:02:45Z",
            duration_ms:    12_400,
            config_commit:  42,
            trigger:        "manual",
            interface_name: nil,
            replay_of:      nil,
            replayable:     true,
            error_summary:  nil,
            steps: [
              { id: 9,  block_name: "fetch_invoice", status: "success", attempt: 1, image: "registry.local/blocks/fetch-invoice:v2", duration_ms: 4_400, exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:02:33Z", finished_at: "2026-05-02T14:02:38Z" },
              { id: 10, block_name: "retry_charge",  status: "success", attempt: 2, image: "registry.local/blocks/retry-charge:v4",  duration_ms: 7_900, exit_code: 0, error_type: nil, error_message: nil, started_at: "2026-05-02T14:02:38Z", finished_at: "2026-05-02T14:02:46Z" }
            ]
          }
        }.freeze

        STEP_PAYLOADS = {
          1  => { input: { "type" => "lead.created", "body" => { "email" => "carol@acme.com", "source" => "form" } }, output: { "lead" => { "raw" => { "email" => "carol@acme.com", "source" => "form" } } } },
          2  => { input: { "lead" => { "raw" => { "email" => "carol@acme.com" } } },                                  output: { "lead" => { "enriched" => { "company" => { "name" => "Acme Inc", "size" => 120, "industry" => "saas" } } } } },
          3  => { input: { "lead" => { "enriched" => { "company" => { "name" => "Acme Inc", "size" => 120 } } } },    output: { "lead" => { "scored" => { "score" => 82, "tier" => "A" } } } },
          4  => { input: { "lead" => { "scored" => { "score" => 82 } } },                                             output: nil },
          5  => { input: { "type" => "lead.created", "body" => { "email" => "bob@example.com" } },                    output: { "lead" => { "raw" => { "email" => "bob@example.com" } } } },
          6  => { input: { "lead" => { "raw" => { "email" => "bob@example.com" } } },                                 output: { "lead" => { "enriched" => { "company" => { "name" => "Example Co", "size" => 50 } } } } },
          7  => { input: { "lead" => { "enriched" => { "company" => { "name" => "Example Co" } } } },                 output: { "lead" => { "scored" => { "score" => 74 } } } },
          8  => { input: { "lead" => { "scored" => { "score" => 74 } } },                                             output: { "notification" => { "result" => "delivered", "channel" => "slack" } } },
          9  => { input: { "type" => "charge.failed", "body" => { "invoice_id" => "in_42" } },                         output: { "invoice" => { "id" => "in_42", "amount_cents" => 2400 } } },
          10 => { input: { "invoice" => { "id" => "in_42", "amount_cents" => 2400 } },                                 output: { "charge" => { "id" => "ch_99", "status" => "captured" } } }
        }.freeze

        CONTEXTS = {
          "run_18492" => {
            input_event: { "type" => "lead.created", "body" => { "email" => "carol@acme.com", "source" => "form" } },
            context: {
              "lead" => {
                "raw" => { "email" => "carol@acme.com", "source" => "form" },
                "enriched" => { "company" => { "name" => "Acme Inc", "size" => 120, "industry" => "saas" } },
                "scored" => { "score" => 82, "tier" => "A" }
              }
            }
          },
          "run_18491" => {
            input_event: { "type" => "lead.created", "body" => { "email" => "bob@example.com" } },
            context: {
              "lead" => {
                "raw" => { "email" => "bob@example.com" },
                "enriched" => { "company" => { "name" => "Example Co", "size" => 50 } },
                "scored" => { "score" => 74 }
              },
              "notification" => { "result" => "delivered", "channel" => "slack" }
            }
          },
          "run_18490" => {
            input_event: { "type" => "charge.failed", "body" => { "invoice_id" => "in_42" } },
            context: {
              "invoice" => { "id" => "in_42", "amount_cents" => 2400 },
              "charge"  => { "id" => "ch_99", "status" => "captured" }
            }
          }
        }.freeze

        LOGS = {
          "run_18492" => [
            { id:  1, run_id: 1, step_id: 1, stream: "system", content: "starting container registry.local/blocks/extract-lead:v1", created_at: "2026-05-02T14:12:44.010Z" },
            { id:  2, run_id: 1, step_id: 1, stream: "stdout", content: "parsed event body",                                          created_at: "2026-05-02T14:12:44.420Z" },
            { id:  3, run_id: 1, step_id: 1, stream: "system", content: "output.json captured (47 bytes)",                            created_at: "2026-05-02T14:12:45.180Z" },
            { id:  4, run_id: 1, step_id: 2, stream: "system", content: "starting container registry.local/blocks/enrich-lead:v3",   created_at: "2026-05-02T14:12:45.220Z" },
            { id:  5, run_id: 1, step_id: 2, stream: "stdout", content: "calling clearbit api",                                       created_at: "2026-05-02T14:12:46.100Z" },
            { id:  6, run_id: 1, step_id: 2, stream: "stdout", content: "clearbit responded 200 OK",                                  created_at: "2026-05-02T14:12:49.840Z" },
            { id:  7, run_id: 1, step_id: 2, stream: "system", content: "output.json captured (180 bytes)",                           created_at: "2026-05-02T14:12:50.020Z" },
            { id:  8, run_id: 1, step_id: 3, stream: "system", content: "starting container registry.local/blocks/score-lead:v2",    created_at: "2026-05-02T14:12:50.060Z" },
            { id:  9, run_id: 1, step_id: 3, stream: "stdout", content: "scored lead: 82",                                            created_at: "2026-05-02T14:12:50.620Z" },
            { id: 10, run_id: 1, step_id: 4, stream: "system", content: "starting container registry.local/blocks/notify-sales:v1",  created_at: "2026-05-02T14:12:50.760Z" },
            { id: 11, run_id: 1, step_id: 4, stream: "stdout", content: "POST /webhook ...",                                          created_at: "2026-05-02T14:12:55.220Z" },
            { id: 12, run_id: 1, step_id: 4, stream: "stderr", content: "expected JSON object, got string",                            created_at: "2026-05-02T14:13:01.870Z" },
            { id: 13, run_id: 1, step_id: 4, stream: "system", content: "block failed: invalid_output (exit=1)",                       created_at: "2026-05-02T14:13:02.010Z" }
          ],
          "run_18491" => [
            { id: 14, run_id: 2, step_id: 5, stream: "system", content: "starting container registry.local/blocks/extract-lead:v1", created_at: "2026-05-02T14:09:11.010Z" },
            { id: 15, run_id: 2, step_id: 8, stream: "stdout", content: "notification delivered to slack",                          created_at: "2026-05-02T14:09:18.000Z" }
          ],
          "run_18490" => []
        }.freeze

        ARTIFACTS = {
          "run_18491" => [
            { id: 1, step_id: 5, block_name: "extract",      name: "lead_raw.json",       size_bytes:    47, content_type: "application/json", checksum: "sha256:aa11", created_at: "2026-05-02T14:09:12Z" },
            { id: 2, step_id: 6, block_name: "enrich",       name: "enrichment.json",     size_bytes:   312, content_type: "application/json", checksum: "sha256:bb22", created_at: "2026-05-02T14:09:16Z" },
            { id: 3, step_id: 8, block_name: "notify_sales", name: "slack_response.json", size_bytes:    98, content_type: "application/json", checksum: "sha256:cc33", created_at: "2026-05-02T14:09:18Z" }
          ],
          "run_18492" => [
            { id: 4, step_id: 4, block_name: "notify_sales", name: "stderr.txt",          size_bytes:    62, content_type: "text/plain",       checksum: "sha256:dd44", created_at: "2026-05-02T14:13:02Z" }
          ],
          "run_18490" => []
        }.freeze

        BOOT_RENDERED = <<~PRC
          router sales_ops
           version 1
           hostname prouter-01
          exit

          queue default
           concurrency 10
           timeout 10m
          exit

          interface webhook leads_in
           path /leads
           method POST
           no shutdown
          exit

          process lead_pipeline
           description "Lead enrichment and sales notification"
           queue default
           no shutdown

           block extract
            image registry.local/blocks/extract-lead:v1
            timeout 30s
            input event.body
            output lead.raw
           exit

           block enrich
            image registry.local/blocks/enrich-lead:v3
            timeout 120s
            input lead.raw
            output lead.enriched
           exit

           block score
            image registry.local/blocks/score-lead:v2
            timeout 20s
            input lead.enriched
            output lead.scored
           exit

           block notify_sales
            image registry.local/blocks/notify-sales:v1
            timeout 15s
            input lead.scored
            output notification.result
           exit

           route extract enrich
           route enrich score
           route score notify_sales
            match lead.scored.score gt 70
           exit
          exit

          route interface leads_in process lead_pipeline
           match event.type eq "lead.created"
          exit
        PRC

        ACTIVE_RENDERED = BOOT_RENDERED
          .sub(" version 1\n", " version 2\n")
          .sub("match lead.scored.score gt 70", "match lead.scored.score gt 80")

        COMMITS = [
          { id: 42, author: "carol", message: "bump score threshold to 80",      checksum: "sha256:c4f2a90b8e1f", created_at: "2026-05-02T12:00:00Z", rendered: ACTIVE_RENDERED },
          { id: 41, author: "bob",   message: "stage version 2 of router",       checksum: "sha256:b3e1758aa921", created_at: "2026-05-01T17:30:00Z", rendered: BOOT_RENDERED.sub(" version 1\n", " version 2\n") },
          { id: 40, author: "alice", message: "no-op refactor",                  checksum: "sha256:a290cccd0f10", created_at: "2026-05-01T11:14:00Z", rendered: BOOT_RENDERED },
          { id: 39, author: "alice", message: "initial commit",                  checksum: "sha256:91003fde7720", created_at: "2026-04-30T09:00:00Z", rendered: BOOT_RENDERED }
        ].freeze

        COMMITS_BY_ID = COMMITS.each_with_object({}) { |c, h| h[c[:id]] = c }.freeze
      end
    end
  end
end

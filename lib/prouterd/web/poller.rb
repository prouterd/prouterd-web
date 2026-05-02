module Prouterd
  module Web
    # Background thread that polls the CoreAdapter at a fixed interval,
    # diffs the result against an in-memory snapshot, and publishes change
    # events on the Broadcaster. This is the "internal polling fallback"
    # called out in spec §43: until the core grows a real pub/sub surface,
    # the web console synthesizes one over SQLite reads.
    #
    # Topics emitted:
    #   "system"          → { type: "system.status_updated", status: {...} }
    #   "runs"            → { type: "run.created" | "run.updated", run: {...} }
    #   "run:<uid>"       → { type: "run.created" | "run.updated", run: {...} }
    #                       { type: "step.created" | "step.updated", step: {...} }
    #   "logs:<uid>"      → { type: "log.appended", log: {...} }
    #
    # Logs are only polled for runs that currently have at least one
    # subscriber on the matching topic — keeps idle runs cheap.
    class Poller
      DEFAULT_PERIOD = 1.0
      VOLATILE_STATUS_FIELDS = %i[uptime_seconds].freeze

      attr_reader :period

      def initialize(adapter:, broadcaster:, period: DEFAULT_PERIOD, logger: nil)
        @adapter     = adapter
        @broadcaster = broadcaster
        @period      = period
        @logger      = logger
        @running     = false
        @thread      = nil

        @last_status_signature = nil
        @run_states  = {}      # uid => { status:, finished_at: }
        @step_states = {}      # uid => { step_id => status }
        @log_cursors = {}      # uid => last log id
      end

      def start
        return if @running

        @running = true
        @thread = Thread.new do
          Thread.current.name = "prouterd-poller" if Thread.current.respond_to?(:name=)
          loop do
            break unless @running

            begin
              tick
            rescue StandardError => e
              warn "[poller] tick error: #{e.class}: #{e.message}"
              warn e.backtrace.first(3).join("\n") if @logger
            end

            sleep @period
          end
        end
        self
      end

      def stop
        @running = false
        @thread&.join(@period * 2 + 1)
        @thread = nil
        self
      end

      def running?
        @running
      end

      # Run a single iteration synchronously. Public so tests can drive the
      # state machine without a background thread.
      def tick
        poll_status
        poll_runs
        poll_logs
      end

      private

      def poll_status
        s = @adapter.status
        sig = status_signature(s)
        return if sig == @last_status_signature

        @last_status_signature = sig
        @broadcaster.publish("system", { type: "system.status_updated", status: s })
      end

      def status_signature(s)
        return nil if s.nil?

        s.reject { |k, _| VOLATILE_STATUS_FIELDS.include?(k) }
      end

      def poll_runs
        runs = @adapter.list_runs(limit: 50)
        runs.each do |r|
          uid = r[:run_uid]
          prev = @run_states[uid]

          if prev.nil?
            event = { type: "run.created", run: r }
            @broadcaster.publish("runs", event)
            @broadcaster.publish("run:#{uid}", event)
          elsif prev[:status] != r[:status] || prev[:finished_at] != r[:finished_at]
            event = { type: "run.updated", run: r }
            @broadcaster.publish("runs", event)
            @broadcaster.publish("run:#{uid}", event)
          end

          @run_states[uid] = { status: r[:status], finished_at: r[:finished_at] }

          poll_steps(uid) if @broadcaster.has_subscribers?("run:#{uid}")
        end
      end

      def poll_steps(run_uid)
        steps = @adapter.get_run_steps(run_uid)
        prev_state = @step_states[run_uid] ||= {}

        steps.each do |s|
          prev_status = prev_state[s[:id]]
          if prev_status.nil?
            @broadcaster.publish("run:#{run_uid}", { type: "step.created", step: s })
          elsif prev_status != s[:status]
            @broadcaster.publish("run:#{run_uid}", { type: "step.updated", step: s })
          end
          prev_state[s[:id]] = s[:status]
        end
      end

      def poll_logs
        @run_states.each_key do |uid|
          next unless @broadcaster.has_subscribers?("logs:#{uid}")

          cursor = @log_cursors[uid] || 0
          logs = @adapter.get_step_logs(uid, after_id: cursor)
          next if logs.empty?

          logs.each do |l|
            @broadcaster.publish("logs:#{uid}", { type: "log.appended", log: l })
          end
          @log_cursors[uid] = logs.last[:id]
        end
      end
    end
  end
end

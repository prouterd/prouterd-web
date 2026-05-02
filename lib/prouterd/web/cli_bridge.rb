require "json"
require "thread"

module Prouterd
  module Web
    # Bridges browser CLI commands to the daemon's WS /v1/cli/:session_id.
    # One persistent WS connection per session_id is held in memory and
    # reused across commands — the connection's lifetime maps 1:1 to the
    # operator's CLI session, not to a single keystroke.
    #
    # Synchronous interface for the WebSocketConnection's `command_executor`:
    #
    #   bridge.dispatch("show running-config", session_id: "sid-1")
    #   # → { exit_code:, stdout:, stderr:, prompt: }
    #
    # `dispatch` blocks the caller until `command.complete` arrives (or the
    # connection drops / times out). Concurrent `dispatch` calls for the
    # same session_id serialize on a per-session mutex; calls for different
    # sessions run in parallel.
    #
    # `client_factory` is injectable for tests: a callable that takes
    # `(url, headers)` and returns a Faye::WebSocket::Client-shaped object
    # exposing `#on(:open|:message|:close|:error, &block)`, `#send(string)`,
    # `#close`. Tests pass an in-memory stub that fires events synchronously
    # without EventMachine.
    class CliBridge
      DEFAULT_TIMEOUT = 30.0

      def initialize(core_url:, token: nil, client_factory: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        @core_url       = core_url
        @token          = token
        @timeout        = timeout
        @logger         = logger
        @client_factory = client_factory || method(:default_factory)

        @sessions       = {}        # session_id => Session
        @sessions_mutex = Mutex.new
      end

      def dispatch(command, session_id:)
        return invalid_session_response unless session_id.is_a?(String) && !session_id.empty?

        session = ensure_session(session_id)
        session.run(command, @timeout)
      end

      def shutdown
        @sessions_mutex.synchronize do
          @sessions.each_value(&:close)
          @sessions.clear
        end
      end

      private

      def ensure_session(session_id)
        @sessions_mutex.synchronize do
          @sessions[session_id] ||= Session.new(
            session_id:     session_id,
            core_url:       @core_url,
            token:          @token,
            client_factory: @client_factory,
            logger:         @logger
          )
        end
      end

      def default_factory(url, headers)
        EventMachineRunner.ensure_running!
        require "faye/websocket"
        Faye::WebSocket::Client.new(url, [], headers: headers)
      end

      def invalid_session_response
        { exit_code: 1, stdout: "", stderr: "% missing session_id\n", prompt: "prouter# " }
      end

      # Per-session_id state. Holds one WS connection that carries every
      # command for the session. Reconnects lazily on the next dispatch
      # if the connection dropped.
      #
      # Threading:
      #   * EM thread fires `on(:open|:message|:close|:error)` callbacks.
      #   * `run` is called by the request thread (Puma worker). It pushes
      #     the next pending command into @pending and blocks on its
      #     completion queue.
      #   * One in-flight command at a time per session — the session
      #     mutex serializes dispatch.
      class Session
        def initialize(session_id:, core_url:, token:, client_factory:, logger: nil)
          @session_id     = session_id
          @core_url       = core_url
          @token          = token
          @client_factory = client_factory
          @logger         = logger
          @run_mutex      = Mutex.new
          @client         = nil
          @open           = false
        end

        def run(command, timeout)
          @run_mutex.synchronize do
            state = State.new
            @state = state
            @pending_command = command   # picked up by on(:open)

            if @open && @client
              send_pending
            else
              unless ensure_open(timeout)
                @state = nil
                return failure("connection failed")
              end
              # If we opened during this call, on(:open) already fired
              # the pending command. If we somehow raced past it (e.g.
              # @open became true before the handler ran), flush here.
              send_pending if @pending_command
            end

            deadline = Time.now + timeout
            until state.done?
              break if Time.now > deadline

              sleep 0.005
            end

            @state = nil

            if state.timed_out?(deadline)
              {
                exit_code: 124,
                stdout:    state.stdout.to_s,
                stderr:    state.stderr.to_s + "% command timed out after #{timeout}s\n",
                prompt:    state.prompt || "prouter# "
              }
            elsif state.error
              {
                exit_code: 1,
                stdout:    state.stdout.to_s,
                stderr:    state.stderr.to_s + "% #{state.error}\n",
                prompt:    state.prompt || "prouter# "
              }
            else
              {
                exit_code: state.exit_code || 1,
                stdout:    state.stdout.to_s,
                stderr:    state.stderr.to_s,
                prompt:    state.prompt || "prouter# "
              }
            end
          end
        end

        def close
          @run_mutex.synchronize do
            begin
              @client&.close
            rescue StandardError
              nil
            end
            @client = nil
            @open   = false
          end
        end

        private

        def ensure_open(timeout)
          return true if @open && @client

          @open   = false
          @client = @client_factory.call(ws_url, bearer_headers)
          wire_handlers(@client)

          deadline = Time.now + timeout
          until @open
            return false if Time.now > deadline

            sleep 0.005
          end
          true
        end

        def wire_handlers(client)
          client.on(:open) do
            @open = true
            send_pending
          end

          client.on(:message) do |event|
            handle_incoming(event.respond_to?(:data) ? event.data : event)
          end

          client.on(:close) do
            @open = false
            @client = nil
            if @state && !@state.done?
              @state.queue.push(:closed)
            end
          end

          client.on(:error) do |event|
            msg = event.respond_to?(:message) ? event.message : event.to_s
            if @state && !@state.done?
              @state.error = msg
              @state.queue.push(:error)
            end
          end
        end

        def handle_incoming(raw)
          msg =
            begin
              JSON.parse(raw.to_s)
            rescue JSON::ParserError
              return
            end

          state = @state
          return unless state

          case msg["type"]
          when "command.output"
            chunk  = msg.dig("payload", "chunk").to_s
            stream = msg.dig("payload", "stream")
            (stream == "stderr" ? state.stderr : state.stdout) << chunk
          when "command.complete"
            state.exit_code = msg.dig("payload", "exit_code")
            state.prompt    = msg.dig("payload", "prompt")
            state.queue.push(:done)
          when "error"
            state.error = msg.dig("payload", "message") || msg["payload"].to_s
            state.queue.push(:error)
          end
        end

        def send_pending
          return unless @pending_command && @client

          send_frame(JSON.dump(id: "c1", type: "command.exec",
                               payload: { command: @pending_command }))
          @pending_command = nil
        end

        def send_frame(frame)
          @client.send(frame)
        rescue StandardError => e
          @state&.error = "send failed: #{e.class}: #{e.message}"
          @state&.queue&.push(:error)
        end

        def ws_url
          "#{@core_url.sub(/\Ahttp/, 'ws')}/v1/cli/#{@session_id}"
        end

        def bearer_headers
          return {} if @token.nil? || @token.empty?

          { "Authorization" => "Bearer #{@token}" }
        end

        def failure(msg)
          { exit_code: 1, stdout: "", stderr: "% #{msg}\n", prompt: "prouter# " }
        end
      end

      class State
        attr_reader :stdout, :stderr, :queue
        attr_accessor :exit_code, :prompt, :error

        def initialize
          @stdout    = +""
          @stderr    = +""
          @exit_code = nil
          @prompt    = nil
          @error     = nil
          @queue     = Queue.new
        end

        def done?
          !@exit_code.nil? || !@error.nil?
        end

        def timed_out?(deadline)
          !done? && Time.now > deadline
        end
      end
    end
  end
end

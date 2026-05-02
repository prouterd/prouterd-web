require "json"
require "thread"

module Prouterd
  module Web
    # Forwards a single CLI command from a browser through to the daemon's
    # WS /v1/cli/:session_id endpoint and aggregates the streamed output
    # into the synchronous result shape the rest of the UI expects.
    #
    # Synchronous interface for the WebSocketConnection's `command_executor`:
    #
    #   bridge.dispatch("show running-config", session_id: "sid-1")
    #   # → { exit_code:, stdout:, stderr:, prompt: }
    #
    # The block call returns once `command.complete` arrives (or the
    # connection drops). Each call opens a fresh WS to the daemon — the
    # daemon keeps the Shell::Session in memory keyed by session_id, so
    # mode_stack and candidate config persist across reconnects.
    #
    # `client_factory` is injectable for tests: a callable that takes
    # `(url, headers)` and returns a Faye::WebSocket::Client-shaped
    # object exposing `#on(:open|:message|:close, &block)`, `#send(string)`,
    # and `#close`. Tests pass an in-memory stub that fires events
    # synchronously without EventMachine.
    class CliBridge
      DEFAULT_TIMEOUT = 30.0

      def initialize(core_url:, token: nil, client_factory: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        @core_url        = core_url
        @token           = token
        @timeout         = timeout
        @logger          = logger
        @client_factory  = client_factory || method(:default_factory)
      end

      def dispatch(command, session_id:)
        return invalid_session_response unless session_id.is_a?(String) && !session_id.empty?

        state = State.new
        client = @client_factory.call(ws_url(session_id), bearer_headers)
        wire_handlers(client, command, state)

        deadline = Time.now + @timeout
        loop do
          break if state.done?
          break if Time.now > deadline
          state.queue.pop(true) rescue Thread.pass
        end

        client.close rescue nil

        if state.timed_out?(deadline)
          {
            exit_code: 124,
            stdout:    state.stdout.to_s,
            stderr:    state.stderr.to_s + "% command timed out after #{@timeout}s\n",
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

      private

      def wire_handlers(client, command, state)
        client.on(:open) do
          frame = { id: "c1", type: "command.exec", payload: { command: command } }
          begin
            client.send(JSON.dump(frame))
          rescue StandardError => e
            state.error = "send failed: #{e.class}: #{e.message}"
            state.queue.push(:error)
          end
        end

        client.on(:message) do |event|
          handle_incoming(event.respond_to?(:data) ? event.data : event, state)
        end

        client.on(:close) do
          state.queue.push(:closed) unless state.done?
        end

        client.on(:error) do |event|
          state.error = event.respond_to?(:message) ? event.message : event.to_s
          state.queue.push(:error)
        end
      end

      def handle_incoming(raw, state)
        msg =
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return
          end

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

      def ws_url(session_id)
        # Convert http[s]:// → ws[s]://
        "#{@core_url.sub(/\Ahttp/, 'ws')}/v1/cli/#{session_id}"
      end

      def bearer_headers
        return {} if @token.nil? || @token.empty?

        { "Authorization" => "Bearer #{@token}" }
      end

      def default_factory(url, headers)
        EventMachineRunner.ensure_running!
        require "faye/websocket"
        Faye::WebSocket::Client.new(url, [], headers: headers)
      end

      def invalid_session_response
        { exit_code: 1, stdout: "", stderr: "% missing session_id\n", prompt: "prouter# " }
      end

      # Per-dispatch in-flight state. The handlers run on the EM thread,
      # the dispatch caller blocks on `queue`. `stdout` / `stderr` / `error`
      # writes happen sequentially from the EM thread, so no extra locking
      # is needed (single producer, single consumer).
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

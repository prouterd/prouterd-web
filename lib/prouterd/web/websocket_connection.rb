require "json"

module Prouterd
  module Web
    # Per-WebSocket-client state. Owns the subscriptions taken out on the
    # broadcaster on this client's behalf, parses inbound protocol frames
    # (spec §14), and serializes outbound events / replies to JSON.
    #
    # The `socket` collaborator only needs to expose `#send(string)` —
    # in production it's a Faye::WebSocket; in tests it's a tiny capture
    # double. Keeping the surface that small is what lets us unit-test
    # the protocol without standing up Puma + faye + a real TCP socket.
    class WebSocketConnection
      class InvalidMessage < StandardError; end

      # `command_executor` is an optional callable: ->(cmd, session_id:) {
      #   { exit_code:, stdout:, stderr:, prompt: }
      # }
      # Production passes a lambda over the adapter; tests use a stub.
      def initialize(socket, broadcaster:, command_executor: nil)
        @socket            = socket
        @broadcaster       = broadcaster
        @command_executor  = command_executor
        @subs              = {}      # topic => broadcaster handle
        @subs_mutex        = Mutex.new
        @send_mutex        = Mutex.new
      end

      # ----- lifecycle -----

      def on_open
        send_message(type: "hello", payload: {
          web_version: defined?(Prouterd::Web::VERSION) ? Prouterd::Web::VERSION : nil
        })
      end

      def on_message(raw)
        msg =
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return send_error(code: "invalid_json", message: "could not parse message")
          end

        type = msg["type"]
        case type
        when "subscribe"    then handle_subscribe(msg)
        when "unsubscribe"  then handle_unsubscribe(msg)
        when "command.exec" then handle_command_exec(msg)
        when "ping"         then send_message(reply_to: msg["id"], type: "pong")
        else
          send_error(code: "unknown_type",
                     message: "unknown message type: #{type.inspect}",
                     reply_to: msg["id"])
        end
      end

      def on_close
        @subs_mutex.synchronize do
          @subs.each_value { |handle| @broadcaster.unsubscribe(handle) }
          @subs.clear
        end
      end

      # ----- inspection (used by tests) -----

      def subscribed_topics
        @subs_mutex.synchronize { @subs.keys.dup }
      end

      private

      def handle_subscribe(msg)
        topic = msg.dig("payload", "topic")
        unless topic.is_a?(String) && !topic.empty?
          return send_error(code: "invalid_payload",
                            message: "subscribe requires payload.topic",
                            reply_to: msg["id"])
        end

        added = false
        @subs_mutex.synchronize do
          unless @subs.key?(topic)
            handle = @broadcaster.subscribe(topic) do |t, payload|
              forward_event(t, payload)
            end
            @subs[topic] = handle
            added = true
          end
        end

        send_message(reply_to: msg["id"],
                     type: added ? "subscribe.ok" : "subscribe.already",
                     payload: { topic: topic })
      end

      def handle_unsubscribe(msg)
        topic = msg.dig("payload", "topic")
        unless topic.is_a?(String) && !topic.empty?
          return send_error(code: "invalid_payload",
                            message: "unsubscribe requires payload.topic",
                            reply_to: msg["id"])
        end

        handle = @subs_mutex.synchronize { @subs.delete(topic) }
        @broadcaster.unsubscribe(handle) if handle

        send_message(reply_to: msg["id"],
                     type: "unsubscribe.ok",
                     payload: { topic: topic })
      end

      def handle_command_exec(msg)
        reply_to   = msg["id"]
        command    = msg.dig("payload", "command")
        session_id = msg.dig("payload", "session_id")

        unless @command_executor
          return send_error(code: "command_unsupported",
                            message: "this connection has no command executor",
                            reply_to: reply_to)
        end
        unless command.is_a?(String) && !command.empty?
          return send_error(code: "invalid_payload",
                            message: "command.exec requires payload.command",
                            reply_to: reply_to)
        end
        unless session_id.is_a?(String) && !session_id.empty?
          return send_error(code: "invalid_payload",
                            message: "command.exec requires payload.session_id",
                            reply_to: reply_to)
        end

        result =
          begin
            @command_executor.call(command, session_id: session_id)
          rescue StandardError => e
            return send_error(code: "command_failed",
                              message: "#{e.class}: #{e.message}",
                              reply_to: reply_to)
          end

        emit_chunks(result[:stdout], stream: "stdout", reply_to: reply_to)
        emit_chunks(result[:stderr], stream: "stderr", reply_to: reply_to)

        send_message(
          reply_to: reply_to,
          type:     "command.complete",
          payload:  {
            exit_code: result[:exit_code],
            prompt:    result[:prompt]
          }
        )
      end

      def emit_chunks(text, stream:, reply_to:)
        return if text.nil? || text.empty?

        text.each_line do |line|
          send_message(reply_to: reply_to,
                       type:     "command.output",
                       payload:  { chunk: line, stream: stream })
        end
      end

      def forward_event(topic, payload)
        # Spec §14 examples don't carry `topic` on event frames, but we add
        # it as a top-level field so the client can dispatch deterministically
        # without inferring topics from `type` + payload shape.
        send_raw(
          topic:   topic,
          type:    payload[:type],
          payload: payload
        )
      end

      def send_message(type:, payload: {}, reply_to: nil)
        msg = { type: type, payload: payload }
        msg[:reply_to] = reply_to if reply_to
        send_raw(msg)
      end

      def send_error(code:, message:, reply_to: nil)
        send_message(type: "error",
                     payload: { code: code, message: message },
                     reply_to: reply_to)
      end

      def send_raw(obj)
        @send_mutex.synchronize do
          @socket.send(JSON.dump(obj))
        end
      rescue StandardError => e
        warn "[ws] send error: #{e.class}: #{e.message}"
      end
    end
  end
end

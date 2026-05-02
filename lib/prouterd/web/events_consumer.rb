require "json"
require "set"
require "uri"

module Prouterd
  module Web
    # WS client that bridges the prouterd daemon's /v1/events stream into
    # our local Broadcaster.
    #
    # Lifecycle (production):
    #   1. Open Faye::WebSocket::Client to ws[s]://core/v1/events with bearer
    #   2. On open → subscribe to baseline topics ("runs", "system")
    #   3. On any incoming `{ topic, type, payload }` frame →
    #      Broadcaster.publish(topic, payload.merge(type: type))
    #   4. The web's WebSocketConnection (server side) calls
    #      `consumer.ensure_upstream_topic(topic)` whenever a browser
    #      subscribes to a per-run / per-log topic — that propagates
    #      the subscription upstream so we receive those events.
    #   5. On close → exponential backoff reconnect; on the next open the
    #      whole `@upstream_topics` set is re-sent.
    #
    # The protocol logic (#on_open / #on_message / #ensure_upstream_topic)
    # is decoupled from the transport so tests can drive it with a fake
    # send-proc and synthetic incoming frames.
    class EventsConsumer
      BASELINE_TOPICS = %w[runs system].freeze

      attr_reader :broadcaster

      def initialize(broadcaster:, logger: nil)
        @broadcaster      = broadcaster
        @logger           = logger
        @send_proc        = nil
        @upstream_topics  = Set.new
        @next_msg_id      = 0
        @mutex            = Mutex.new
      end

      # Wire the WS write side. Production passes a lambda over
      # Faye::WebSocket::Client#send; tests pass a capture lambda.
      def attach(send_proc)
        @send_proc = send_proc
      end

      def detach
        @send_proc = nil
      end

      # Called when the WS handshake to core completes (initial or after
      # reconnect). Re-subscribes upstream to everything we previously
      # cared about.
      def on_open
        @mutex.synchronize { BASELINE_TOPICS.each { |t| @upstream_topics << t } }
        existing = @mutex.synchronize { @upstream_topics.to_a }
        existing.each { |t| send_subscribe(t) }
      end

      # Called for every incoming WS frame. Translates into a local
      # Broadcaster publish so the rest of the UI sees the same kind of
      # event the in-process Poller used to emit.
      def on_message(raw)
        msg =
          begin
            JSON.parse(raw.to_s)
          rescue JSON::ParserError
            return
          end

        return unless msg.is_a?(Hash)

        topic = msg["topic"]
        type  = msg["type"]
        return unless topic.is_a?(String) && type.is_a?(String)

        payload = msg["payload"] || {}
        payload = payload.merge("type" => type) if payload.is_a?(Hash)

        @broadcaster.publish(topic, payload)
      end

      def on_close
        # Caller (transport adapter) handles reconnect. We just clear the
        # send proc so any concurrent ensure_upstream_topic call no-ops
        # until the next #attach.
        detach
      end

      # Idempotent: ensures a `subscribe` frame for `topic` has been sent
      # upstream. Called by the web's WebSocketConnection whenever a
      # browser subscribes to a per-run / per-log topic.
      def ensure_upstream_topic(topic)
        return unless topic.is_a?(String) && !topic.empty?

        first_time = false
        @mutex.synchronize do
          unless @upstream_topics.include?(topic)
            @upstream_topics << topic
            first_time = true
          end
        end

        send_subscribe(topic) if first_time
      end

      def upstream_topics
        @mutex.synchronize { @upstream_topics.to_a }
      end

      private

      def send_subscribe(topic)
        return unless @send_proc

        frame = {
          id:      next_id,
          type:    "subscribe",
          payload: { topic: topic }
        }
        begin
          @send_proc.call(JSON.dump(frame))
        rescue StandardError => e
          @logger&.error("[events_consumer] send error: #{e.class}: #{e.message}")
        end
      end

      def next_id
        @mutex.synchronize do
          @next_msg_id += 1
          "ec_#{@next_msg_id}"
        end
      end
    end
  end
end

module Prouterd
  module Web
    # Tiny in-process pub/sub bus keyed by topic. Subscribers register a
    # callable; publishers fan out to all current subscribers of a topic.
    #
    # Used as the meeting point between the Poller (which observes the core
    # and emits change events) and per-connection WebSocket handlers (which
    # forward those events to clients). Threading: subscribe / unsubscribe /
    # publish are safe to call concurrently. Subscriber callbacks run in
    # whichever thread called publish — keep them quick and non-blocking
    # (e.g. enqueue to a per-connection channel rather than doing IO inline).
    class Broadcaster
      def initialize
        @mutex   = Mutex.new
        @subs    = {}      # topic => { id => callable }
        @next_id = 0
      end

      # Returns an opaque handle ([topic, id]) usable with #unsubscribe.
      def subscribe(topic, &block)
        raise ArgumentError, "block required" unless block

        @mutex.synchronize do
          @next_id += 1
          (@subs[topic] ||= {})[@next_id] = block
          [topic, @next_id]
        end
      end

      def unsubscribe(handle)
        return unless handle

        topic, id = handle
        @mutex.synchronize do
          if (bucket = @subs[topic])
            bucket.delete(id)
            @subs.delete(topic) if bucket.empty?
          end
        end
      end

      def publish(topic, payload)
        callbacks = @mutex.synchronize { @subs[topic]&.values&.dup || [] }
        callbacks.each do |cb|
          begin
            cb.call(topic, payload)
          rescue StandardError => e
            warn "[broadcaster] subscriber error on #{topic}: #{e.class}: #{e.message}"
          end
        end
      end

      def has_subscribers?(topic)
        @mutex.synchronize { !@subs[topic].nil? && !@subs[topic].empty? }
      end

      def topics
        @mutex.synchronize { @subs.keys.dup }
      end

      def subscriber_count(topic)
        @mutex.synchronize { @subs[topic]&.size || 0 }
      end

      # Test helper: clear all subscriptions.
      def clear
        @mutex.synchronize { @subs.clear }
      end
    end
  end
end

module Prouterd
  module Web
    # Faye::WebSocket::Client (used by EventsConsumer and CliBridge) needs
    # an EventMachine reactor in the process. Puma itself doesn't run one,
    # so we lazily spin up a single EM reactor on a daemon thread the
    # first time anyone needs it.
    module EventMachineRunner
      @mutex = Mutex.new

      module_function

      def ensure_running!
        @mutex.synchronize do
          require "eventmachine"
          return if EM.reactor_running?

          Thread.new do
            Thread.current.name = "prouterd-em" if Thread.current.respond_to?(:name=)
            EM.run
          end

          deadline = Time.now + 2.0
          until EM.reactor_running? || Time.now > deadline
            Thread.pass
            sleep 0.005
          end

          raise "EventMachine reactor failed to start within 2s" unless EM.reactor_running?
        end
      end
    end
  end
end

module Prouterd
  module Web
    module Helpers
      # Display-time redaction for JSON values shown in the console (run
      # context, step input/output, input events). Walks nested Hashes /
      # Arrays and replaces values whose key looks sensitive with the
      # literal string "[REDACTED]".
      #
      # Secret values, authorization headers, bearer tokens, and known
      # env secret values must never appear in operator views. Logs
      # are already redacted by core's Redactor at write time, so we only
      # need to handle inbound user-supplied JSON (input events) plus any
      # context payloads that happen to carry credentials inline.
      #
      # The redactor is conservative: it matches by key name only. It does
      # not try to detect bare tokens in free-text fields — that's a job
      # for core to handle when capturing logs.
      module Redactor
        SENSITIVE_KEY_RE = /\A(
          authorization | auth |
          password | passwd | passphrase |
          secret | secrets |
          token | tokens | access[_-]?token | refresh[_-]?token | bearer |
          api[_-]?key | apikey |
          cookie | session[_-]?id |
          private[_-]?key | client[_-]?secret
        )\z/x.freeze

        REDACTED = "[REDACTED]".freeze

        module_function

        def scrub(value)
          case value
          when Hash
            value.each_with_object({}) do |(k, v), h|
              h[k] = sensitive_key?(k) ? REDACTED : scrub(v)
            end
          when Array
            value.map { |v| scrub(v) }
          else
            value
          end
        end

        def sensitive_key?(key)
          SENSITIVE_KEY_RE.match?(key.to_s.downcase)
        end
      end
    end
  end
end

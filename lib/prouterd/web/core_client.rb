require "json"
require "net/http"
require "uri"

module Prouterd
  module Web
    # Thin HTTP client for the prouterd daemon's /v1 surface. Owns the
    # bearer-auth header, JSON serialization/parsing, and translation of
    # the daemon's error envelope into typed Ruby exceptions.
    #
    # The transport is pluggable: production uses NetHttpTransport, specs
    # use RackTestTransport that drives a stub Rack app in-process. Both
    # implement the same `#call(method:, path:, query:, body:, headers:)`
    # contract returning `{status:, headers:, body:}`.
    class CoreClient
      class Error           < StandardError; end
      class BadRequest      < Error; end
      class Unauthorized    < Error; end
      class Forbidden       < Error; end
      class NotFound        < Error; end
      class Conflict        < Error; end
      class ValidationError < Error; end
      class ServerError     < Error; end
      class TransportError  < Error; end

      attr_reader :base_url

      def initialize(base_url:, token: nil, transport: nil, retries: 1, logger: nil)
        @base_url  = base_url
        @token     = token
        @transport = transport || NetHttpTransport.new(base_url)
        @retries   = retries
        @logger    = logger
      end

      # ----- HTTP verbs (parsed JSON body) -----

      def get(path, query = {})
        request_json(:get, path, query: query)
      end

      def post(path, body = nil)
        request_json(:post, path, body: body)
      end

      # ----- raw bytes (for artifact download) -----

      def get_bytes(path, query = {})
        resp = transport_call(:get, path, query: query, body: nil, headers: bearer_headers)
        raise_for_status(resp, parsed_error: nil)
        { status: resp[:status], headers: resp[:headers], body: resp[:body] }
      end

      # ----- raw text (config rendered as DSL) -----

      def get_text(path, query = {})
        resp = transport_call(:get, path, query: query, body: nil, headers: bearer_headers)
        raise_for_status(resp, parsed_error: nil)
        resp[:body]
      end

      def post_text(path, body)
        resp = transport_call(
          :post, path,
          query: {}, body: body,
          headers: bearer_headers.merge("Content-Type" => "text/plain")
        )
        parsed = parse_json_body(resp)
        raise_for_status(resp, parsed_error: parsed)
        parsed
      end

      private

      # ----- request engine -----

      def request_json(method, path, query: {}, body: nil)
        encoded_body = body.nil? ? nil : JSON.dump(body)
        headers = bearer_headers
        headers = headers.merge("Content-Type" => "application/json") if encoded_body

        attempts = 0
        begin
          resp = transport_call(method, path, query: query, body: encoded_body, headers: headers)
        rescue TransportError => e
          attempts += 1
          if attempts <= @retries
            retry
          end
          raise e
        end

        parsed = parse_json_body(resp)
        raise_for_status(resp, parsed_error: parsed)
        parsed
      end

      def transport_call(method, path, query:, body:, headers:)
        @transport.call(method: method, path: path, query: query, body: body, headers: headers)
      rescue StandardError => e
        raise TransportError, "#{e.class}: #{e.message}"
      end

      def bearer_headers
        h = { "Accept" => "application/json" }
        h["Authorization"] = "Bearer #{@token}" if @token && !@token.empty?
        h
      end

      def parse_json_body(resp)
        return nil if resp[:body].nil? || resp[:body].empty?

        ct = resp[:headers].find { |k, _| k.to_s.casecmp?("content-type") }&.last.to_s
        return resp[:body] unless ct.start_with?("application/json")

        JSON.parse(resp[:body])
      rescue JSON::ParserError
        resp[:body]
      end

      def raise_for_status(resp, parsed_error:)
        status = resp[:status].to_i
        return if status >= 200 && status < 300

        message = error_message_from(parsed_error) || "HTTP #{status}"
        case status
        when 400      then raise BadRequest,      message
        when 401      then raise Unauthorized,    message
        when 403      then raise Forbidden,       message
        when 404      then raise NotFound,        message
        when 409      then raise Conflict,        message
        when 410      then raise NotFound,        message
        when 422      then raise ValidationError, message
        when 500..599 then raise ServerError,     message
        else raise Error, message
        end
      end

      def error_message_from(parsed)
        return nil unless parsed.is_a?(Hash)

        parsed["error"] || parsed[:error]
      end

      # ----- production transport -----

      class NetHttpTransport
        def initialize(base_url)
          @base = URI(base_url)
        end

        def call(method:, path:, query:, body:, headers:)
          uri = build_uri(path, query)
          req = build_request(method, uri, body, headers)

          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.read_timeout = 30
            http.open_timeout = 5
            http.request(req)
          end

          {
            status:  response.code.to_i,
            headers: response.each_header.to_h,
            body:    response.body
          }
        end

        private

        def build_uri(path, query)
          uri = @base.dup
          uri.path = path
          unless query.nil? || query.empty?
            uri.query = URI.encode_www_form(query.transform_values(&:to_s))
          end
          uri
        end

        def build_request(method, uri, body, headers)
          klass = {
            get:    Net::HTTP::Get,
            post:   Net::HTTP::Post,
            put:    Net::HTTP::Put,
            delete: Net::HTTP::Delete
          }.fetch(method)

          req = klass.new(uri.request_uri)
          headers.each { |k, v| req[k] = v }
          req.body = body if body
          req
        end
      end
    end
  end
end

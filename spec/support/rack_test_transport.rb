require "json"
require "rack/mock"
require "uri"

module Prouterd
  module Web
    module Specs
      # Transport that drives a Rack app in-process via Rack::MockRequest.
      # Used in specs to exercise the CoreClient + HttpApiAdapter against
      # a stub /v1 implementation without spinning up a real HTTP server.
      class RackTestTransport
        def initialize(app)
          @app = app
        end

        def call(method:, path:, query: {}, body: nil, headers: {})
          uri = path.dup
          unless query.nil? || query.empty?
            qs = query.map { |k, v| "#{URI.encode_www_form_component(k.to_s)}=#{URI.encode_www_form_component(v.to_s)}" }.join("&")
            uri = "#{uri}?#{qs}"
          end

          mock = Rack::MockRequest.new(@app)
          opts = {}
          headers.each { |k, v| opts["HTTP_#{k.upcase.tr('-', '_')}"] = v unless k.casecmp?("Content-Type") }
          opts["CONTENT_TYPE"] = headers["Content-Type"] || headers["content-type"] if headers.any? { |k, _| k.casecmp?("Content-Type") }
          opts[:input] = body if body

          response = mock.request(method.to_s.upcase, uri, opts)
          {
            status:  response.status,
            headers: response.headers.transform_keys { |k| k.to_s.downcase },
            body:    response.body
          }
        end
      end
    end
  end
end

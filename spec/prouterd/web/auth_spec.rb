require "spec_helper"

RSpec.describe "auth (Phase UI-9)" do
  include Rack::Test::Methods

  let(:stub_and_adapter) do
    stub      = Prouterd::Web::Specs::StubCoreApp.new
    seed_demo_stub(stub)
    transport = Prouterd::Web::Specs::RackTestTransport.new(stub)
    client    = Prouterd::Web::CoreClient.new(base_url: "http://stub", transport: transport)
    adapter   = Prouterd::Web::Adapters::HttpApiAdapter.new(client: client)
    [stub, adapter]
  end
  let(:adapter) { stub_and_adapter.last }

  describe "with auth_token configured" do
    let(:token) { "s3cret-token" }
    let(:app)   { Prouterd::Web::App.with_adapter(adapter, auth_token: token) }
    let(:expected_cookie) { Prouterd::Web::App.digest_token(token) }

    it "redirects HTML requests on /console to /login when unauthed" do
      get "/console"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/login")
    end

    it "401 JSONs API requests when unauthed" do
      get "/windows/system"
      expect(last_response.status).to eq(401)
      expect(last_response.headers["Content-Type"]).to start_with("application/json")
      expect(JSON.parse(last_response.body)["error"]).to include("auth")
    end

    it "lets /assets through without auth" do
      get "/assets/app.css"
      expect(last_response.status).to eq(200)
    end

    it "lets /health through without auth" do
      get "/health"
      expect(last_response.status).to eq(200)
    end

    it "GET /login renders the form" do
      get "/login"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("<form")
      expect(last_response.body).to include('name="token"')
      expect(last_response.body).not_to include("class=\"top-bar\"")  # no layout
    end

    it "POST /login with the right token sets the cookie and redirects to /console" do
      post "/login", { token: token }
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/console")

      cookie = last_response.headers["Set-Cookie"]
      expect(cookie).to include(Prouterd::Web::App::COOKIE_NAME)
      expect(cookie).to include(expected_cookie)
      expect(cookie.downcase).to include("httponly")
      expect(cookie.downcase).to include("samesite=strict")
    end

    it "POST /login with the wrong token re-renders with 401 + error" do
      post "/login", { token: "nope" }
      expect(last_response.status).to eq(401)
      expect(last_response.body).to include("Invalid token")
    end

    it "lets requests through once the cookie is set" do
      set_cookie "#{Prouterd::Web::App::COOKIE_NAME}=#{expected_cookie}"
      get "/console"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("class=\"top-bar\"")
    end

    it "logout clears the cookie and redirects" do
      set_cookie "#{Prouterd::Web::App::COOKIE_NAME}=#{expected_cookie}"
      post "/logout"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/login")
      expect(last_response.headers["Set-Cookie"]).to include("#{Prouterd::Web::App::COOKIE_NAME}=")
    end

    it "rejects WS upgrade without a valid cookie (no upgrade headers, returns 401 JSON)" do
      get "/ws"
      expect(last_response.status).to eq(401)
    end
  end

  describe "with no auth configured (development default)" do
    let(:app) { Prouterd::Web::App.with_adapter(adapter) }

    it "lets /console through without a cookie" do
      get "/console"
      expect(last_response.status).to eq(200)
    end

    it "POST /login with no auth simply redirects to /console" do
      post "/login", { token: "anything" }
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/console")
    end
  end

  describe "security response headers" do
    let(:app) { Prouterd::Web::App.with_adapter(adapter) }

    it "sets X-Content-Type-Options / X-Frame-Options / Referrer-Policy on every response" do
      get "/console"
      expect(last_response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(last_response.headers["X-Frame-Options"]).to eq("DENY")
      expect(last_response.headers["Referrer-Policy"]).to eq("same-origin")
    end

    it "sets a strict Content-Security-Policy" do
      get "/console"
      csp = last_response.headers["Content-Security-Policy"]
      expect(csp).to include("default-src 'self'")
      expect(csp).to include("script-src 'self'")
      expect(csp).to include("connect-src 'self' ws: wss:")
      expect(csp).to include("frame-ancestors 'none'")
    end
  end
end

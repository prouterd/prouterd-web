require "spec_helper"

RSpec.describe Prouterd::Web::CoreClient do
  let(:stub)       { Prouterd::Web::Specs::StubCoreApp.new }
  let(:transport)  { Prouterd::Web::Specs::RackTestTransport.new(stub) }
  subject(:client) { described_class.new(base_url: "http://stub", token: nil, transport: transport) }

  describe "#get" do
    it "returns parsed JSON for 200 OK" do
      stub.processes = [{ name: "p", description: nil, queue: "q", shutdown: false, blocks: 0, routes: 0 }]
      result = client.get("/v1/processes")
      expect(result["data"]).to eq([{ "name" => "p", "description" => nil, "queue" => "q",
                                      "shutdown" => false, "blocks" => 0, "routes" => 0 }])
    end

    it "raises NotFound on 404" do
      expect { client.get("/v1/processes/ghost") }.to raise_error(Prouterd::Web::CoreClient::NotFound)
    end

    it "encodes query params" do
      stub.runs = { "run_a" => { uid: "run_a", process_name: "x", status: "success" },
                    "run_b" => { uid: "run_b", process_name: "y", status: "running" } }
      result = client.get("/v1/runs", { process: "x" })
      expect(result["data"].size).to eq(1)
      expect(result["data"].first["uid"]).to eq("run_a")
    end
  end

  describe "#post" do
    it "sends a JSON body and returns 202 envelope" do
      stub.processes = [{ name: "p" }]
      result = client.post("/v1/processes/p/trigger", type: "x")
      expect(result["data"]["run_id"]).to start_with("run_stub_")
      expect(stub.triggered_runs.first[:body]).to eq("type" => "x")
    end

    it "raises Conflict on 409" do
      expect { client.post("/v1/config/save-boot") }.to raise_error(Prouterd::Web::CoreClient::Conflict)
    end
  end

  describe "auth" do
    it "sends bearer token in Authorization header" do
      stub.token = "secret"
      authed = described_class.new(base_url: "http://stub", token: "secret", transport: transport)
      expect { authed.get("/v1/processes") }.not_to raise_error
    end

    it "raises Unauthorized when token is missing and required" do
      stub.token = "secret"
      anon = described_class.new(base_url: "http://stub", token: nil, transport: transport)
      expect { anon.get("/v1/processes") }.to raise_error(Prouterd::Web::CoreClient::Unauthorized)
    end

    it "raises Forbidden on wrong token" do
      stub.token = "right"
      bad = described_class.new(base_url: "http://stub", token: "wrong", transport: transport)
      expect { bad.get("/v1/processes") }.to raise_error(Prouterd::Web::CoreClient::Forbidden)
    end
  end

  describe "#get_text" do
    it "returns plain-text body without JSON parsing" do
      stub.running_config_text = "router demo\nexit\n"
      expect(client.get_text("/v1/config/running")).to eq("router demo\nexit\n")
    end
  end

  describe "#get_bytes" do
    it "returns raw bytes with content headers" do
      stub.artifacts_by_id[42] = { id: 42, name: "out.json", content_type: "application/json", size_bytes: 11 }
      stub.artifact_bytes[42]  = '{"ok":true}'
      result = client.get_bytes("/v1/artifacts/42/download")
      expect(result[:status]).to eq(200)
      expect(result[:body]).to eq('{"ok":true}')
      expect(result[:headers]["content-disposition"]).to include("out.json")
    end
  end

  describe "transport errors" do
    let(:flaky_transport) do
      Class.new do
        attr_accessor :calls
        def initialize; @calls = 0; end
        def call(*); @calls += 1; raise "network down"; end
      end.new
    end

    it "retries once on transport failures, then raises TransportError" do
      bad = described_class.new(base_url: "http://stub", transport: flaky_transport, retries: 1)
      expect { bad.get("/v1/processes") }.to raise_error(Prouterd::Web::CoreClient::TransportError)
      expect(flaky_transport.calls).to eq(2)  # 1 initial + 1 retry
    end
  end
end

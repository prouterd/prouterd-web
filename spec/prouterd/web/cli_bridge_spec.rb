require "spec_helper"
require "json"

RSpec.describe Prouterd::Web::CliBridge do
  # In-memory stub that fires events synchronously from the controller
  # thread — no EventMachine needed for unit tests.
  class FakeWsClient
    attr_reader :sent, :closed

    def initialize
      @handlers = Hash.new { |h, k| h[k] = [] }
      @sent     = []
      @closed   = false
    end

    def on(event, &block)
      @handlers[event] << block
    end

    def send(data)
      @sent << data
    end

    def close
      @closed = true
      fire(:close)
    end

    def fire(event, payload = nil)
      ev = payload.nil? ? Object.new : Struct.new(:data, :message).new(payload, payload)
      @handlers[event].each { |h| h.call(ev) }
    end

    def fire_message(json)
      fire(:message, json)
    end
  end

  let(:client) { FakeWsClient.new }

  let(:factory) do
    captured = nil
    proc do |url, headers|
      captured = { url: url, headers: headers }
      client
    end.tap { |p| p.singleton_class.attr_accessor(:captured) }
  end

  subject(:bridge) do
    described_class.new(
      core_url:       "http://core:9000",
      token:          "secret",
      client_factory: ->(url, headers) { client },
      timeout:        2.0
    )
  end

  describe "#dispatch happy path" do
    it "sends command.exec and aggregates output until command.complete" do
      Thread.new do
        sleep 0.01
        client.fire(:open)
        client.fire_message(JSON.dump(type: "command.output", payload: { chunk: "hello\n", stream: "stdout" }))
        client.fire_message(JSON.dump(type: "command.output", payload: { chunk: "world\n", stream: "stdout" }))
        client.fire_message(JSON.dump(type: "command.complete", payload: { exit_code: 0, prompt: "router# " }))
      end

      result = bridge.dispatch("show running-config", session_id: "sid-1")

      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to eq("hello\nworld\n")
      expect(result[:stderr]).to eq("")
      expect(result[:prompt]).to eq("router# ")

      sent = JSON.parse(client.sent.first)
      expect(sent["type"]).to eq("command.exec")
      expect(sent.dig("payload", "command")).to eq("show running-config")
    end

    it "separates stderr from stdout" do
      Thread.new do
        sleep 0.01
        client.fire(:open)
        client.fire_message(JSON.dump(type: "command.output", payload: { chunk: "out", stream: "stdout" }))
        client.fire_message(JSON.dump(type: "command.output", payload: { chunk: "err", stream: "stderr" }))
        client.fire_message(JSON.dump(type: "command.complete", payload: { exit_code: 1, prompt: "router# " }))
      end

      result = bridge.dispatch("oops", session_id: "sid-1")
      expect(result[:stdout]).to eq("out")
      expect(result[:stderr]).to eq("err")
      expect(result[:exit_code]).to eq(1)
    end
  end

  describe "error frames" do
    it "surfaces an error frame as stderr + exit_code 1" do
      Thread.new do
        sleep 0.01
        client.fire(:open)
        client.fire_message(JSON.dump(type: "error", payload: { code: "invalid_payload", message: "no command" }))
      end

      result = bridge.dispatch("garbage", session_id: "sid-1")
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include("no command")
    end
  end

  describe "timeouts" do
    it "returns exit_code 124 if no command.complete arrives in time" do
      tight = described_class.new(
        core_url:       "http://core:9000",
        client_factory: ->(_, _) { client },
        timeout:        0.05
      )
      Thread.new { sleep 0.01; client.fire(:open) }

      result = tight.dispatch("hangs", session_id: "sid-1")
      expect(result[:exit_code]).to eq(124)
      expect(result[:stderr]).to include("timed out")
    end
  end

  describe "validation" do
    it "returns an error result when session_id is empty" do
      result = bridge.dispatch("show", session_id: "")
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include("session_id")
    end
  end

  describe "URL construction" do
    it "swaps http→ws and embeds the session_id in the path" do
      captured = nil
      capturing_factory = lambda do |url, headers|
        captured = { url: url, headers: headers }
        client
      end
      b = described_class.new(core_url: "http://core:9000", token: "t", client_factory: capturing_factory, timeout: 0.05)

      Thread.new { sleep 0.01; client.fire(:open); client.fire_message(JSON.dump(type: "command.complete", payload: { exit_code: 0, prompt: "x" })) }
      b.dispatch("noop", session_id: "abc")

      expect(captured[:url]).to eq("ws://core:9000/v1/cli/abc")
      expect(captured[:headers]["Authorization"]).to eq("Bearer t")
    end

    it "swaps https→wss" do
      captured = nil
      capturing_factory = lambda do |url, _|
        captured = { url: url }
        client
      end
      b = described_class.new(core_url: "https://core:9000", client_factory: capturing_factory, timeout: 0.05)

      Thread.new { sleep 0.01; client.fire(:open); client.fire_message(JSON.dump(type: "command.complete", payload: { exit_code: 0, prompt: "x" })) }
      b.dispatch("noop", session_id: "abc")

      expect(captured[:url]).to start_with("wss://")
    end
  end
end

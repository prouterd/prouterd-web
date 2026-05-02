require "spec_helper"
require "json"

RSpec.describe Prouterd::Web::WebSocketConnection do
  # Capture-only socket: records what would have been written on the wire.
  let(:socket) do
    Class.new do
      attr_reader :sent
      def initialize; @sent = []; end
      def send(s); @sent << s; end
    end.new
  end

  let(:broadcaster) { Prouterd::Web::Broadcaster.new }
  subject(:conn)    { described_class.new(socket, broadcaster: broadcaster) }

  def last_sent_msg
    JSON.parse(socket.sent.last)
  end

  describe "#on_open" do
    it "emits a hello frame with the web version" do
      conn.on_open
      msg = last_sent_msg
      expect(msg["type"]).to eq("hello")
      expect(msg.dig("payload", "web_version")).to eq(Prouterd::Web::VERSION)
    end
  end

  describe "subscribe" do
    it "registers with the broadcaster and acks with subscribe.ok" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))

      expect(broadcaster.has_subscribers?("runs")).to be true
      ack = last_sent_msg
      expect(ack["reply_to"]).to eq("m1")
      expect(ack["type"]).to eq("subscribe.ok")
      expect(ack.dig("payload", "topic")).to eq("runs")
    end

    it "is idempotent — subsequent identical subscribes get subscribe.already" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      conn.on_message(JSON.dump(id: "m2", type: "subscribe", payload: { topic: "runs" }))

      expect(broadcaster.subscriber_count("runs")).to eq(1)
      expect(last_sent_msg["type"]).to eq("subscribe.already")
    end

    it "errors when payload.topic is missing" do
      conn.on_message(JSON.dump(id: "m3", type: "subscribe", payload: {}))
      err = last_sent_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("invalid_payload")
      expect(err["reply_to"]).to eq("m3")
    end
  end

  describe "broadcaster events" do
    it "are forwarded to the client as topic-tagged frames" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      socket.sent.clear  # drop the hello/ack frames

      broadcaster.publish("runs", { "type" => "run.updated", "run" => { "uid" => "run_42" } })

      msg = last_sent_msg
      expect(msg["topic"]).to eq("runs")
      expect(msg["type"]).to eq("run.updated")
      expect(msg.dig("payload", "run", "uid")).to eq("run_42")
    end
  end

  describe "unsubscribe" do
    it "drops the broadcaster subscription and acks" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe",   payload: { topic: "runs" }))
      conn.on_message(JSON.dump(id: "m2", type: "unsubscribe", payload: { topic: "runs" }))

      expect(broadcaster.has_subscribers?("runs")).to be false
      ack = last_sent_msg
      expect(ack["reply_to"]).to eq("m2")
      expect(ack["type"]).to eq("unsubscribe.ok")
    end
  end

  describe "ping" do
    it "responds with pong tagged to the request id" do
      conn.on_message(JSON.dump(id: "ping_1", type: "ping"))
      msg = last_sent_msg
      expect(msg["type"]).to eq("pong")
      expect(msg["reply_to"]).to eq("ping_1")
    end
  end

  describe "invalid input" do
    it "emits a typed error on JSON parse failure" do
      conn.on_message("{not json")
      err = last_sent_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("invalid_json")
    end

    it "emits a typed error on unknown message type" do
      conn.on_message(JSON.dump(id: "x", type: "frobnicate"))
      err = last_sent_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("unknown_type")
      expect(err["reply_to"]).to eq("x")
    end
  end

  describe "command.exec" do
    let(:executor) do
      ->(cmd, session_id:) {
        @last_call = { cmd: cmd, session_id: session_id }
        { exit_code: 0, stdout: "first line\nsecond line\n", stderr: "", prompt: "test# " }
      }
    end

    let(:conn) { Prouterd::Web::WebSocketConnection.new(socket, broadcaster: broadcaster, command_executor: executor) }

    it "errors when no executor is configured" do
      noexec = Prouterd::Web::WebSocketConnection.new(socket, broadcaster: broadcaster)
      noexec.on_message(JSON.dump(id: "c1", type: "command.exec", payload: { command: "x", session_id: "s" }))
      err = last_sent_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("command_unsupported")
    end

    it "validates payload shape" do
      conn.on_message(JSON.dump(id: "c1", type: "command.exec", payload: {}))
      err = last_sent_msg
      expect(err.dig("payload", "code")).to eq("invalid_payload")
    end

    it "streams output as command.output frames and finishes with command.complete" do
      conn.on_message(JSON.dump(id: "c1", type: "command.exec",
                                payload: { command: "show foo", session_id: "s1" }))

      # Skip the hello/ack lines this test happens to emit; pull all frames.
      msgs = socket.sent.map { |s| JSON.parse(s) }
      outputs = msgs.select { |m| m["type"] == "command.output" }
      expect(outputs.size).to eq(2)
      expect(outputs[0].dig("payload", "chunk")).to eq("first line\n")
      expect(outputs[0].dig("payload", "stream")).to eq("stdout")
      expect(outputs[1].dig("payload", "chunk")).to eq("second line\n")
      expect(outputs.first["reply_to"]).to eq("c1")

      complete = msgs.last
      expect(complete["type"]).to eq("command.complete")
      expect(complete["reply_to"]).to eq("c1")
      expect(complete.dig("payload", "exit_code")).to eq(0)
      expect(complete.dig("payload", "prompt")).to eq("test# ")
    end

    it "emits stderr as command.output frames with stream=stderr" do
      bad_executor = ->(*) { { exit_code: 1, stdout: "", stderr: "% boom\n", prompt: "test# " } }
      conn2 = Prouterd::Web::WebSocketConnection.new(socket, broadcaster: broadcaster, command_executor: bad_executor)

      conn2.on_message(JSON.dump(id: "c2", type: "command.exec",
                                 payload: { command: "go boom", session_id: "s1" }))
      streams = socket.sent.map { |s| JSON.parse(s) }
                       .select { |m| m["type"] == "command.output" }
                       .map { |m| m.dig("payload", "stream") }
      expect(streams).to include("stderr")
    end

    it "wraps executor exceptions as command_failed errors" do
      raising = ->(*) { raise "kaboom" }
      conn3 = Prouterd::Web::WebSocketConnection.new(socket, broadcaster: broadcaster, command_executor: raising)
      conn3.on_message(JSON.dump(id: "c3", type: "command.exec",
                                 payload: { command: "x", session_id: "s1" }))
      err = last_sent_msg
      expect(err["type"]).to eq("error")
      expect(err.dig("payload", "code")).to eq("command_failed")
      expect(err.dig("payload", "message")).to include("kaboom")
    end
  end

  describe "#on_close" do
    it "drops every broadcaster subscription it held" do
      conn.on_message(JSON.dump(id: "m1", type: "subscribe", payload: { topic: "runs" }))
      conn.on_message(JSON.dump(id: "m2", type: "subscribe", payload: { topic: "system" }))

      conn.on_close

      expect(broadcaster.has_subscribers?("runs")).to be false
      expect(broadcaster.has_subscribers?("system")).to be false
      expect(conn.subscribed_topics).to be_empty
    end
  end
end

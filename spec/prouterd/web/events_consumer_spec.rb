require "spec_helper"
require "json"

RSpec.describe Prouterd::Web::EventsConsumer do
  let(:broadcaster) { Prouterd::Web::Broadcaster.new }
  subject(:consumer) { described_class.new(broadcaster: broadcaster) }

  let(:sent) { [] }

  before { consumer.attach(->(frame) { sent << frame }) }

  def parsed_sent
    sent.map { |s| JSON.parse(s) }
  end

  describe "#on_open" do
    it "subscribes upstream to baseline topics (runs, system)" do
      consumer.on_open
      topics = parsed_sent.map { |m| m.dig("payload", "topic") }
      expect(topics).to include("runs", "system")
      expect(parsed_sent).to all(include("type" => "subscribe"))
    end

    it "resubscribes to all previously-known topics after reconnect" do
      consumer.on_open                                 # baseline
      consumer.ensure_upstream_topic("run:run_42")    # add a per-run topic
      consumer.detach
      sent.clear

      # Simulate reconnect: attach a fresh send_proc, on_open replays.
      consumer.attach(->(frame) { sent << frame })
      consumer.on_open

      topics = parsed_sent.map { |m| m.dig("payload", "topic") }
      expect(topics).to include("runs", "system", "run:run_42")
    end
  end

  describe "#on_message" do
    it "publishes the inbound payload to the local Broadcaster on the matching topic" do
      received = []
      broadcaster.subscribe("runs") { |topic, payload| received << [topic, payload] }
      consumer.on_message(JSON.dump(topic: "runs", type: "run.updated",
                                    payload: { uid: "run_42", status: "success" }))
      expect(received.size).to eq(1)
      topic, payload = received.first
      expect(topic).to eq("runs")
      expect(payload["uid"]).to eq("run_42")
      expect(payload["type"]).to eq("run.updated")  # type folded into payload
    end

    it "is silent on garbage frames" do
      expect { consumer.on_message("not json") }.not_to raise_error
      expect { consumer.on_message(JSON.dump(no: "topic")) }.not_to raise_error
    end

    it "doesn't deliver when the local topic has no subscribers" do
      expect {
        consumer.on_message(JSON.dump(topic: "logs:nobody", type: "log.appended", payload: {}))
      }.not_to raise_error
    end
  end

  describe "#ensure_upstream_topic" do
    it "is idempotent — repeat calls don't duplicate subscribes" do
      consumer.ensure_upstream_topic("run:run_42")
      consumer.ensure_upstream_topic("run:run_42")
      sub_count = parsed_sent.count { |m| m.dig("payload", "topic") == "run:run_42" }
      expect(sub_count).to eq(1)
    end

    it "buffers topics added before the WS opens, replays on reconnect" do
      consumer.detach   # simulate not-yet-connected
      consumer.ensure_upstream_topic("logs:run_42")
      expect(sent).to be_empty

      consumer.attach(->(frame) { sent << frame })
      consumer.on_open
      topics = parsed_sent.map { |m| m.dig("payload", "topic") }
      expect(topics).to include("logs:run_42")
    end

    it "ignores empty / nil topic names" do
      consumer.ensure_upstream_topic(nil)
      consumer.ensure_upstream_topic("")
      expect(sent).to be_empty
    end
  end

  describe "#on_close" do
    it "detaches send_proc so further upstream sends no-op" do
      consumer.attach(->(frame) { sent << frame })
      consumer.on_close
      consumer.ensure_upstream_topic("logs:run_42")
      expect(sent).to be_empty
    end
  end

  describe "integration with the Broadcaster" do
    it "real subscribers receive forwarded payloads end-to-end" do
      received = []
      broadcaster.subscribe("run:run_42") { |_, payload| received << payload }

      consumer.on_message(JSON.dump(
        topic: "run:run_42", type: "step.updated",
        payload: { id: 7, block_name: "extract", status: "success" }
      ))

      expect(received.first["block_name"]).to eq("extract")
      expect(received.first["type"]).to eq("step.updated")
    end
  end
end

require "spec_helper"

RSpec.describe Prouterd::Web::Broadcaster do
  subject(:bus) { described_class.new }

  it "delivers a published payload to a subscriber on the matching topic" do
    received = []
    bus.subscribe("runs") { |topic, payload| received << [topic, payload] }

    bus.publish("runs", { type: "run.created", run_uid: "run_1" })

    expect(received).to eq([["runs", { type: "run.created", run_uid: "run_1" }]])
  end

  it "does not deliver to subscribers on other topics" do
    received_a = []
    received_b = []
    bus.subscribe("a") { |_t, p| received_a << p }
    bus.subscribe("b") { |_t, p| received_b << p }

    bus.publish("a", :alpha)

    expect(received_a).to eq([:alpha])
    expect(received_b).to be_empty
  end

  it "delivers to multiple subscribers on the same topic" do
    a = b = nil
    bus.subscribe("x") { |_t, p| a = p }
    bus.subscribe("x") { |_t, p| b = p }

    bus.publish("x", 42)

    expect(a).to eq(42)
    expect(b).to eq(42)
  end

  it "stops delivering after unsubscribe" do
    delivered = 0
    handle = bus.subscribe("x") { delivered += 1 }
    bus.publish("x", :first)
    bus.unsubscribe(handle)
    bus.publish("x", :second)

    expect(delivered).to eq(1)
  end

  it "isolates subscriber failures so other subscribers still get the event" do
    delivered = 0
    bus.subscribe("x") { raise "boom" }
    bus.subscribe("x") { delivered += 1 }

    expect { bus.publish("x", :p) }.not_to raise_error
    expect(delivered).to eq(1)
  end

  describe "#has_subscribers?" do
    it "is false for empty topic and true with a subscriber" do
      expect(bus.has_subscribers?("topic")).to be false
      handle = bus.subscribe("topic") { }
      expect(bus.has_subscribers?("topic")).to be true
      bus.unsubscribe(handle)
      expect(bus.has_subscribers?("topic")).to be false
    end
  end
end

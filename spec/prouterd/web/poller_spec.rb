require "spec_helper"

RSpec.describe Prouterd::Web::Poller do
  let(:broadcaster) { Prouterd::Web::Broadcaster.new }

  # Stub adapter whose responses can be swapped between ticks.
  let(:adapter) do
    Class.new do
      attr_accessor :status_value, :runs_value, :steps_by_uid, :logs_by_uid

      def initialize
        @status_value = base_status
        @runs_value   = []
        @steps_by_uid = {}
        @logs_by_uid  = {}
      end

      def status; @status_value; end
      def list_runs(*) @runs_value; end
      def get_run_steps(uid); @steps_by_uid[uid] || []; end
      def get_step_logs(uid, step_id: nil, after_id: nil)
        rows = @logs_by_uid[uid] || []
        rows = rows.select { |l| l[:id] > after_id.to_i } if after_id
        rows
      end

      def base_status
        { router: "test", queue_depth: 0, uptime_seconds: 0 }
      end
    end.new
  end

  subject(:poller) { described_class.new(adapter: adapter, broadcaster: broadcaster, period: 9999) }

  describe "system status" do
    it "publishes on first tick and again only when meaningful fields change" do
      events = []
      broadcaster.subscribe("system") { |_t, p| events << p }

      poller.tick                                      # initial publish
      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq("system.status_updated")

      adapter.status_value = adapter.base_status.merge(uptime_seconds: 99)
      poller.tick                                      # only volatile field changed → no publish
      expect(events.size).to eq(1)

      adapter.status_value = adapter.base_status.merge(queue_depth: 5)
      poller.tick                                      # real change → publish
      expect(events.size).to eq(2)
    end
  end

  describe "runs" do
    it "emits run.created on first sighting and run.updated on status change" do
      runs_events = []
      run_events  = []
      broadcaster.subscribe("runs")        { |_t, p| runs_events << p }
      broadcaster.subscribe("run:run_42")  { |_t, p| run_events  << p }

      adapter.runs_value = [{ run_uid: "run_42", status: "queued",  finished_at: nil }]
      poller.tick

      adapter.runs_value = [{ run_uid: "run_42", status: "running", finished_at: nil }]
      poller.tick

      expect(runs_events.map { |e| e[:type] }).to eq(["run.created", "run.updated"])
      expect(run_events.map  { |e| e[:type] }).to eq(["run.created", "run.updated"])
    end
  end

  describe "steps" do
    it "polls steps only for runs that have a run:<uid> subscriber" do
      adapter.runs_value     = [{ run_uid: "run_42", status: "running", finished_at: nil }]
      adapter.steps_by_uid   = { "run_42" => [{ id: 1, status: "success" }] }

      # No subscriber on run:run_42 yet → poller should not emit step events.
      step_events = []
      poller.tick
      expect(step_events).to be_empty

      # Subscribe and poll again — step.created should fire now.
      broadcaster.subscribe("run:run_42") { |_t, p| step_events << p }
      poller.tick
      expect(step_events.map { |e| e[:type] }).to include("step.created")

      # Step status flips → step.updated.
      adapter.steps_by_uid = { "run_42" => [{ id: 1, status: "failed" }] }
      poller.tick
      expect(step_events.map { |e| e[:type] }).to include("step.updated")
    end
  end

  describe "logs" do
    it "publishes log.appended only when topic has subscribers, and advances cursor" do
      adapter.runs_value   = [{ run_uid: "run_42", status: "running", finished_at: nil }]
      adapter.logs_by_uid  = { "run_42" => [{ id: 1, content: "a" }, { id: 2, content: "b" }] }

      poller.tick                                       # no subscribers → no logs published
      log_events = []

      broadcaster.subscribe("logs:run_42") { |_t, p| log_events << p[:log] }
      poller.tick                                       # publishes both
      expect(log_events.map { |l| l[:id] }).to eq([1, 2])

      poller.tick                                       # cursor advanced → nothing new
      expect(log_events.map { |l| l[:id] }).to eq([1, 2])

      adapter.logs_by_uid["run_42"] << { id: 3, content: "c" }
      poller.tick
      expect(log_events.map { |l| l[:id] }).to eq([1, 2, 3])
    end
  end

  describe "lifecycle" do
    it "starts and stops the background thread cleanly" do
      poller.start
      expect(poller.running?).to be true
      poller.stop
      expect(poller.running?).to be false
    end
  end
end

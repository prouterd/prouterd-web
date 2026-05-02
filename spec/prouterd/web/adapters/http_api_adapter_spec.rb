require "spec_helper"

RSpec.describe Prouterd::Web::Adapters::HttpApiAdapter do
  let(:stub)      { Prouterd::Web::Specs::StubCoreApp.new }
  let(:transport) { Prouterd::Web::Specs::RackTestTransport.new(stub) }
  let(:client)    { Prouterd::Web::CoreClient.new(base_url: "http://stub", transport: transport) }
  subject(:adapter) { described_class.new(client: client) }

  describe "#status" do
    it "maps /v1/status into the UI shape" do
      stub.status_payload = {
        "version" => "0.1.0", "router" => "sales_ops",
        "running_commit" => 42, "startup_commit" => 39,
        "interfaces" => 1, "processes" => 2, "accepting" => true,
        "in_flight" => 3
      }
      s = adapter.status
      expect(s).to include(
        router:        "sales_ops",
        active_commit: 42,
        boot_commit:   39,
        config_drift:  true,
        healthy:       true,
        workers:       3
      )
    end

    it "returns an unhealthy stub on transport / server failure" do
      bad = described_class.new(client: Prouterd::Web::CoreClient.new(
        base_url: "http://stub",
        transport: Class.new { def call(*); raise "down"; end }.new
      ))
      s = bad.status
      expect(s[:healthy]).to be false
    end
  end

  describe "config" do
    before do
      stub.commits = [
        { id: 42, checksum: "sha256:c4f2", short_checksum: "c4f2", author: "carol", message: "current",  created_at: "2026-05-02T12:00:00Z" },
        { id: 39, checksum: "sha256:9100", short_checksum: "9100", author: "alice", message: "boot",     created_at: "2026-04-30T09:00:00Z" }
      ]
      stub.running_commit_id = 42
      stub.startup_commit_id = 39
      stub.running_config_text = "router demo\n version 2\nexit\n"
      stub.startup_config_text = "router demo\n version 1\nexit\n"
    end

    it "active_config returns the running commit + rendered text" do
      ac = adapter.active_config
      expect(ac[:commit][:id]).to eq(42)
      expect(ac[:rendered]).to include("version 2")
    end

    it "boot_config returns the startup commit + rendered text" do
      bc = adapter.boot_config
      expect(bc[:commit][:id]).to eq(39)
      expect(bc[:rendered]).to include("version 1")
    end

    it "list_commits returns summaries newest first (as the daemon orders)" do
      ids = adapter.list_commits.map { |c| c[:id] }
      expect(ids).to eq([42, 39])
    end

    it "get_commit nil for unknown" do
      expect(adapter.get_commit(9999)).to be_nil
    end

    it "config_diff joins commits via the same Helpers::ConfigDiff used by SqliteAdapter" do
      stub.commits.first.merge!(rendered_config: "router demo\n version 2\nexit\n")
      stub.commits.last.merge!(rendered_config:  "router demo\n version 1\nexit\n")
      diff = adapter.config_diff(left: 39, right: 42)
      kinds = diff.map { |r| r[:action] }
      expect(kinds).to include("-")
      expect(kinds).to include("+")
    end
  end

  describe "config-derived collections" do
    before do
      stub.interfaces = [{ name: "leads_in", type: "webhook", shutdown: false }]
      stub.queues     = [{ name: "default",  concurrency: 4, timeout_ms: 60_000 }]
      stub.policies   = [{ name: "retry_standard", retry_attempts: 3, retry_backoff: "exponential",
                           retry_initial_delay_ms: 5_000, retry_max_delay_ms: 120_000, timeout_ms: nil }]
      stub.secrets    = [{ name: "CLEARBIT_API_KEY", source_type: "env", source_ref: "CLEARBIT_API_KEY",
                           used_by: ["block enrich"], status: "missing" }]
    end

    it "list_interfaces maps type → :kind and shutdown → :status" do
      ifaces = adapter.list_interfaces
      expect(ifaces.first).to include(name: "leads_in", kind: "webhook", status: "enabled")
    end

    it "list_queues / list_policies / list_secrets pass through" do
      expect(adapter.list_queues.first).to   include(name: "default", concurrency: 4)
      expect(adapter.list_policies.first).to include(name: "retry_standard", retry_attempts: 3)
      expect(adapter.list_secrets.first).to  include(name: "CLEARBIT_API_KEY", status: "missing")
    end
  end

  describe "processes" do
    before do
      stub.processes = [
        {
          name: "lead_pipeline", description: "demo", queue: "default", shutdown: false,
          blocks: [
            { "name" => "extract", "image" => "alpine", "timeout_ms" => 30_000, "input" => "event.body",
              "output" => "lead.raw", "retry_policy" => nil, "shutdown" => false }
          ],
          routes: [
            { "from" => "extract", "to" => "enrich", "matches" => [], "on_failure" => "stop" }
          ]
        }
      ]
    end

    it "list_processes shrinks to summary with block / route counts" do
      p = adapter.list_processes.first
      expect(p[:name]).to eq("lead_pipeline")
      expect(p[:blocks]).to eq(1)
      expect(p[:routes]).to eq(1)
      expect(p[:status]).to eq("enabled")
    end

    it "get_process expands blocks + routes" do
      p = adapter.get_process("lead_pipeline")
      expect(p[:blocks].first).to include(name: "extract", image: "alpine")
      expect(p[:routes].first).to include(from: "extract", to: "enrich", on_failure: "stop")
    end

    it "list_routes(process: name) returns process-scoped routes" do
      routes = adapter.list_routes(process: "lead_pipeline")
      expect(routes.first[:from]).to eq("extract")
    end

    it "list_blocks flattens across processes with :process tag" do
      blocks = adapter.list_blocks
      expect(blocks.first).to include(name: "extract", process: "lead_pipeline")
    end
  end

  describe "runs" do
    before do
      stub.runs = {
        "run_1" => {
          uid: "run_1", process_name: "p", status: "success",
          interface_name: "cli", commit_id: 42, replay_of: nil,
          duration_ms: 1500, started_at: nil, finished_at: nil,
          input_event_json: '{"type":"x"}', context_json: '{"k":"v"}',
          steps: [
            { id: 1, block_name: "extract", status: "success", attempt: 1,
              image: "alpine", exit_code: 0, duration_ms: 100,
              input_json: '{"a":1}', output_json: '{"b":2}' }
          ]
        }
      }
    end

    it "list_runs maps uid → :run_uid, commit_id → :config_commit, interface_name → :trigger" do
      runs = adapter.list_runs
      expect(runs.first).to include(run_uid: "run_1", process_name: "p", config_commit: 42, trigger: "cli")
    end

    it "get_run merges in :replayable based on terminal status" do
      r = adapter.get_run("run_1")
      expect(r[:replayable]).to be true
      expect(r[:error_summary]).to be_nil
    end

    it "get_run returns nil on 404" do
      expect(adapter.get_run("run_zzz")).to be_nil
    end

    it "get_run_steps maps step rows" do
      steps = adapter.get_run_steps("run_1")
      expect(steps.first).to include(block_name: "extract", status: "success", duration_ms: 100)
    end

    it "get_step parses input_json and output_json" do
      step = adapter.get_step("run_1", 1)
      expect(step[:input_json]).to eq("a" => 1)
      expect(step[:output_json]).to eq("b" => 2)
    end

    it "get_run_context returns parsed event + context" do
      ctx = adapter.get_run_context("run_1")
      expect(ctx[:input_event]).to eq("type" => "x")
      expect(ctx[:context]).to eq("k" => "v")
    end

    it "count_runs filters by process_name" do
      stub.runs["run_2"] = { uid: "run_2", process_name: "other", status: "queued" }
      expect(adapter.count_runs).to                                eq(2)
      expect(adapter.count_runs(process_name: "p")).to              eq(1)
      expect(adapter.count_runs(process_name: "other")).to          eq(1)
      expect(adapter.count_runs(process_name: "no_such_proc")).to   eq(0)
    end
  end

  describe "run actions" do
    before do
      stub.processes = [{ name: "p", description: nil, queue: "q", shutdown: false, blocks: 1, routes: 0 }]
      stub.runs["run_1"] = { uid: "run_1", process_name: "p", status: "running" }
    end

    it "trigger_process posts the input event and returns the new run uid" do
      result = adapter.trigger_process("p", { "type" => "x" })
      expect(result[:run_uid]).to start_with("run_stub_")
      expect(stub.triggered_runs.first[:body]).to eq("type" => "x")
    end

    it "trigger_process returns :error for unknown process" do
      result = adapter.trigger_process("ghost", {})
      expect(result[:error]).to be_a(String)
    end

    it "replay_run posts and returns the new run uid + replay_of link" do
      result = adapter.replay_run("run_1", from_block: "extract")
      expect(result[:run_uid]).to start_with("run_replay_")
      expect(result[:replay_of]).to eq("run_1")
      expect(result[:from_block]).to eq("extract")
      expect(stub.replayed_runs.first).to eq(uid: "run_1", from_block: "extract")
    end

    it "replay_run nil for unknown run" do
      expect(adapter.replay_run("run_zzz")).to be_nil
    end

    it "cancel_run returns true on 200, false on conflict" do
      expect(adapter.cancel_run("run_1")).to be true
      expect(stub.canceled_runs).to include("run_1")
      # Re-canceling: now terminal → 409
      expect(adapter.cancel_run("run_1")).to be false
    end
  end

  describe "config actions" do
    before do
      stub.commits = [{ id: 42, checksum: "sha256:c4f2", author: "carol", message: "x", created_at: "2026-05-02T00:00:00Z" }]
      stub.running_commit_id = nil
    end

    it "rollback_config posts and returns the new active commit summary" do
      stub.running_commit_id = nil
      result = adapter.rollback_config(42)
      expect(result[:id]).to eq(42)
      expect(stub.rolled_back).to eq([42])
    end

    it "rollback_config returns nil for unknown commit" do
      expect(adapter.rollback_config(9999)).to be_nil
    end

    it "save_boot_config returns the blessed commit when running pointer exists" do
      stub.running_commit_id = 42
      result = adapter.save_boot_config
      expect(result[:id]).to eq(42)
      expect(stub.saved_boot).to eq(1)
    end

    it "save_boot_config returns nil when 409" do
      stub.running_commit_id = nil
      expect(adapter.save_boot_config).to be_nil
    end
  end

  describe "trace_event" do
    it "posts to /v1/trace and returns the daemon's tracer payload" do
      stub.trace_payload = {
        "global_route_passes" => true,
        "process" => "lead_pipeline",
        "graph" => [{ "block" => "extract", "depends_on" => nil }]
      }
      result = adapter.trace_event({ "type" => "lead.created" }, interface_name: "leads_in")
      expect(result["process"]).to eq("lead_pipeline")
      expect(result["graph"].first["block"]).to eq("extract")
    end
  end

  describe "logs / artifacts" do
    before do
      stub.runs["run_1"] = { uid: "run_1", process_name: "p", status: "success" }
      stub.run_logs["run_1"] = [
        { id: 1, run_id: 1, step_id: 1, stream: "stdout", content: "hi\n",  created_at: "2026-05-02T00:00:00Z" },
        { id: 2, run_id: 1, step_id: 2, stream: "stderr", content: "oops\n", created_at: "2026-05-02T00:00:01Z" }
      ]
      stub.run_artifacts["run_1"] = [
        { id: 7, step_id: 1, block_name: "extract", name: "out.json", size_bytes: 11,
          content_type: "application/json", checksum: "sha256:aa", created_at: "2026-05-02T00:00:00Z", path: "/tmp/x" }
      ]
    end

    it "get_step_logs filters by step_id via query param" do
      logs = adapter.get_step_logs("run_1", step_id: 1)
      expect(logs.size).to eq(1)
      expect(logs.first[:stream]).to eq("stdout")
    end

    it "get_run_artifacts returns shaped rows" do
      arts = adapter.get_run_artifacts("run_1")
      expect(arts.first).to include(name: "out.json", content_type: "application/json", size_bytes: 11)
    end

    it "fetch_artifact_bytes streams bytes via /v1/artifacts/:id/download" do
      stub.artifacts_by_id[7] = stub.run_artifacts["run_1"].first
      stub.artifact_bytes[7]  = '{"ok":true}'
      bytes = adapter.fetch_artifact_bytes(7)
      expect(bytes[:body]).to eq('{"ok":true}')
      expect(bytes[:content_type]).to eq("application/json")
    end

    it "fetch_artifact_bytes returns nil on 404" do
      expect(adapter.fetch_artifact_bytes(9999)).to be_nil
    end
  end
end

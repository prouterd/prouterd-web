require "spec_helper"

RSpec.describe Prouterd::Web::Adapters::MockAdapter do
  subject(:adapter) { described_class.new }

  describe "#status" do
    it "returns the router-shaped hash the top bar expects" do
      s = adapter.status
      expect(s).to include(
        :router, :healthy, :web_version,
        :active_commit, :boot_commit, :config_drift,
        :workers, :queue_depth
      )
      expect(s[:web_version]).to eq(Prouterd::Web::VERSION)
    end
  end

  describe "#list_processes" do
    it "returns process descriptors" do
      expect(adapter.list_processes).to all(
        include(:name, :status, :blocks, :routes, :queue)
      )
    end
  end

  describe "#list_runs" do
    it "returns run descriptors keyed by run_uid" do
      expect(adapter.list_runs).to all(
        include(:run_uid, :process_name, :status)
      )
    end
  end

  describe "#get_process" do
    it "returns rich detail for known fixtures" do
      p = adapter.get_process("lead_pipeline")
      expect(p[:name]).to eq("lead_pipeline")
      expect(p[:blocks].map { |b| b[:name] }).to eq(%w[extract enrich score notify_sales])
      expect(p[:routes]).not_to be_empty
    end

    it "returns nil for unknown processes" do
      expect(adapter.get_process("not_real")).to be_nil
    end
  end

  describe "#get_run / #get_run_steps" do
    it "exposes the failing run with its steps" do
      run = adapter.get_run("run_18492")
      expect(run[:status]).to eq("failed")
      expect(run[:replayable]).to be true
      expect(run[:error_summary]).to include("notify_sales")

      steps = adapter.get_run_steps("run_18492")
      expect(steps.last).to include(block_name: "notify_sales", status: "failed")
    end

    it "returns nil/empty for unknown uids" do
      expect(adapter.get_run("run_zzzz")).to be_nil
      expect(adapter.get_run_steps("run_zzzz")).to eq([])
    end
  end

  describe "#get_step / #get_run_context / #get_step_logs / #get_run_artifacts" do
    it "returns step detail with parsed input / output JSON" do
      step = adapter.get_step("run_18492", 2)
      expect(step[:block_name]).to eq("enrich")
      expect(step[:input_json]).to be_a(Hash)
      expect(step[:output_json].dig("lead", "enriched", "company", "name")).to eq("Acme Inc")
    end

    it "returns run context with input event and final context" do
      ctx = adapter.get_run_context("run_18492")
      expect(ctx[:input_event]["type"]).to eq("lead.created")
      expect(ctx[:context].dig("lead", "scored", "score")).to eq(82)
    end

    it "returns logs filtered by step" do
      logs = adapter.get_step_logs("run_18492", step_id: 4)
      expect(logs.map { |l| l[:step_id] }.uniq).to eq([4])
      expect(logs.any? { |l| l[:stream] == "stderr" }).to be true
    end

    it "filters logs by after_id for incremental polling" do
      logs = adapter.get_step_logs("run_18492", after_id: 10)
      expect(logs.map { |l| l[:id] }).to all(be > 10)
    end

    it "returns artifacts for a run" do
      arts = adapter.get_run_artifacts("run_18491")
      expect(arts.map { |a| a[:name] }).to include("enrichment.json")
    end

    it "returns artifacts filtered by step" do
      arts = adapter.get_run_artifacts("run_18491", step_id: 8)
      expect(arts).to all(include(step_id: 8))
    end
  end

  describe "config views" do
    it "exposes active and boot configs with rendered text" do
      expect(adapter.active_config[:commit][:id]).to eq(42)
      expect(adapter.boot_config[:commit][:id]).to eq(39)
      expect(adapter.active_config[:rendered]).to include("router sales_ops")
    end

    it "lists commits newest first" do
      expect(adapter.list_commits.map { |c| c[:id] }).to eq([42, 41, 40, 39])
    end

    it "diffs two commits and the result has at least one - and + row" do
      diff = adapter.config_diff(left: 39, right: 42)
      actions = diff.map { |r| r[:action] }
      expect(actions).to include("-")
      expect(actions).to include("+")
    end

    it "rollback updates the active pointer" do
      adapter.rollback_config(40)
      expect(adapter.status[:active_commit]).to eq(40)
      expect(adapter.status[:config_drift]).to be true
    end

    it "save_boot_config equalizes pointers" do
      adapter.save_boot_config
      expect(adapter.status[:config_drift]).to be false
      expect(adapter.status[:boot_commit]).to eq(adapter.status[:active_commit])
    end
  end

  describe "run actions" do
    it "trigger creates a runtime run that lists alongside fixtures" do
      r = adapter.trigger_process("lead_pipeline", { "type" => "lead.created" })
      expect(r[:run_uid]).to start_with("run_")
      uids = adapter.list_runs.map { |x| x[:run_uid] }
      expect(uids).to include(r[:run_uid])
    end

    it "trigger errors for unknown processes" do
      r = adapter.trigger_process("no_such_process", {})
      expect(r[:error]).to be_a(String)
    end

    it "replay creates a run with replay_of set" do
      r = adapter.replay_run("run_18492")
      expect(r[:replay_of]).to eq("run_18492")
      expect(r[:run_uid]).to start_with("run_")
    end

    it "replay nil for unknown run" do
      expect(adapter.replay_run("run_zzz")).to be_nil
    end

    it "cancel succeeds on a freshly triggered run and fails on terminal/unknown" do
      uid = adapter.trigger_process("lead_pipeline", {})[:run_uid]
      expect(adapter.cancel_run(uid)).to be(true)
      # Calling cancel again on the now-canceled run is a no-op
      expect(adapter.cancel_run(uid)).to be(false)
      expect(adapter.cancel_run("run_zzz")).to be(false)
    end

    it "get_artifact returns nil (mock has no bytes)" do
      expect(adapter.get_artifact(1)).to be_nil
    end
  end

  describe "embedded CLI" do
    it "executes a real shell command and returns stdout / exit_code / prompt" do
      r = adapter.execute_cli_command("show running-config", session_id: "s1")
      expect(r[:exit_code]).to eq(0)
      expect(r[:stdout]).to be_a(String)
      expect(r[:prompt]).to match(/[#] $/)  # prouter#-style
    end

    it "produces a typed error on unknown commands" do
      r = adapter.execute_cli_command("not_a_command", session_id: "s1")
      expect(r[:exit_code]).to eq(1)
      expect(r[:stderr]).to match(/^%/)
    end

    it "preserves session state between calls (mode stack survives)" do
      a = adapter.execute_cli_command("show running-config", session_id: "shared")
      prompt_before = a[:prompt]
      adapter.execute_cli_command("?", session_id: "shared")
      after_prompt = adapter.cli_prompt("shared")
      expect(after_prompt).to eq(prompt_before)
    end

    it "isolates state across distinct session ids" do
      adapter.execute_cli_command("show running-config", session_id: "alpha")
      adapter.execute_cli_command("show running-config", session_id: "beta")
      expect(adapter.cli_prompt("alpha")).to eq(adapter.cli_prompt("beta"))
    end
  end

  describe "an unimplemented method" do
    it "raises NotImplementedYet from the base class" do
      expect { adapter.trace_event({}, interface_name: "leads_in") }
        .to raise_error(Prouterd::Web::CoreAdapter::NotImplementedYet)
    end
  end
end

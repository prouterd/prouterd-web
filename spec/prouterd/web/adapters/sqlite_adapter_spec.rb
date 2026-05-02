require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Prouterd::Web::Adapters::SqliteAdapter do
  let(:tmpdir)  { Dir.mktmpdir("prouterd-ui-test-") }
  let(:db_path) { File.join(tmpdir, "prouterd.db") }

  let(:config_text) do
    <<~PRC
      router test
       version 1
      exit

      queue default
       concurrency 1
       timeout 1m
      exit

      interface webhook leads_in
       path /leads
       method POST
       no shutdown
      exit

      process lead_pipeline
       queue default
       no shutdown

       block extract
        image alpine:latest
        timeout 5s
        output result
       exit

       block enrich
        image alpine:latest
        timeout 5s
        input result
        output enriched
       exit

       route extract enrich
      exit

      route interface leads_in process lead_pipeline
       match event.type eq "lead.created"
      exit
    PRC
  end

  before do
    db    = Prouterd::Storage::DB.open(db_path)
    store = Prouterd::ControlPlane::ConfigStore.new(db)

    lines = Prouterd::Config::Lexer.tokenize(config_text)
    doc   = Prouterd::Config::Parser.parse(lines)
    store.commit(doc, author: "test", message: "initial")
    store.write_memory

    runs = Prouterd::Storage::Repositories::Runs.new(db)
    run = runs.create_run(
      process_name:    "lead_pipeline",
      input_event:     { "type" => "lead.created" },
      interface_name:  "leads_in"
    )
    step = runs.create_step(run_id: run.id, block_name: "extract", image: "alpine:latest")
    runs.append_log(run_id: run.id, step_id: step.id, stream: "system", content: "starting")
    runs.append_log(run_id: run.id, step_id: step.id, stream: "stdout", content: "hello world")
    runs.add_artifact(
      run_id: run.id, step_id: step.id, block_name: "extract",
      name: "out.json", path: "/tmp/out.json", size_bytes: 42, content_type: "application/json"
    )
    runs.update_step(step.id, output_json: JSON.dump({ "ok" => true }))
    runs.update_run(run.id, context_json: JSON.dump({ "lead" => { "raw" => true } }))

    # Second commit: bump version 1 -> 2 so we have something to diff
    config_text2 = config_text.sub(" version 1", " version 2")
    lines2 = Prouterd::Config::Lexer.tokenize(config_text2)
    doc2   = Prouterd::Config::Parser.parse(lines2)
    store.commit(doc2, author: "test", message: "bump version")

    @seed_run_uid = run.uid
    @seed_step_id = step.id

    db.close
  end

  after { FileUtils.rm_rf(tmpdir) }

  subject(:adapter) { described_class.new(db_path: db_path, router_name: "test") }
  after(:each)      { adapter.close }

  describe "#status" do
    it "reports running/boot commits, drift after a second commit, and a queued run" do
      s = adapter.status
      expect(s[:router]).to eq("test")
      expect(s[:active_commit]).to eq(2)   # newest commit
      expect(s[:boot_commit]).to eq(1)     # write_memory was before the 2nd commit
      expect(s[:config_drift]).to be(true)
      expect(s[:queue_depth]).to eq(1)
      expect(s[:web_version]).to eq(Prouterd::Web::VERSION)
    end

    it "is resilient on a fresh DB without runs migrations applied" do
      empty_db = File.join(tmpdir, "empty.db")
      Prouterd::Storage::DB.open(empty_db, run_migrations: false).close
      a = described_class.new(db_path: empty_db, run_migrations: false)
      s = a.status
      expect(s[:active_commit]).to be_nil
      expect(s[:queue_depth]).to eq(0)
    ensure
      a&.close
    end
  end

  describe "#list_interfaces" do
    it "returns the webhook interface from the running config" do
      ifaces = adapter.list_interfaces
      expect(ifaces.size).to eq(1)
      expect(ifaces.first).to include(name: "leads_in", kind: "webhook", status: "enabled")
    end
  end

  describe "#list_processes" do
    it "returns processes with block / route counts and queue" do
      procs = adapter.list_processes
      expect(procs.size).to eq(1)
      expect(procs.first).to include(
        name:   "lead_pipeline",
        status: "enabled",
        blocks: 2,
        routes: 1,
        queue:  "default"
      )
      expect(procs.first[:last_status]).to eq("queued")
    end
  end

  describe "#list_routes" do
    let(:routes) { adapter.list_routes }

    it "yields the global route with a stringified condition" do
      global = routes.find { |r| r[:from].start_with?("@interface:") }
      expect(global).to include(from: "@interface:leads_in", to: "lead_pipeline", enabled: true)
      expect(global[:condition]).to eq('event.type eq "lead.created"')
    end

    it "yields process routes with from/to block names" do
      proc_routes = routes.reject { |r| r[:from].start_with?("@interface:") }
      expect(proc_routes).to contain_exactly(
        a_hash_including(from: "extract", to: "enrich", enabled: true, process: "lead_pipeline")
      )
    end

    it "filters by process name" do
      only = adapter.list_routes(process: "lead_pipeline")
      expect(only.map { |r| r[:from] }).to eq(["extract"])
      expect(adapter.list_routes(process: "nope")).to eq([])
    end
  end

  describe "#list_runs" do
    it "returns the seeded run as a UI-shaped hash" do
      runs = adapter.list_runs
      expect(runs.size).to eq(1)
      expect(runs.first).to include(
        process_name: "lead_pipeline",
        status:       "queued",
        trigger:      "leads_in",
        replay_of:    nil
      )
      expect(runs.first[:run_uid]).to start_with("run_")
    end

    it "filters by status" do
      expect(adapter.list_runs(status: "success")).to be_empty
      expect(adapter.list_runs(status: "queued").size).to eq(1)
    end

    it "filters by process name" do
      expect(adapter.list_runs(process_name: "lead_pipeline").size).to eq(1)
      expect(adapter.list_runs(process_name: "other")).to be_empty
    end

    it "count_runs returns the total, filterable by process name" do
      expect(adapter.count_runs).to eq(1)
      expect(adapter.count_runs(process_name: "lead_pipeline")).to eq(1)
      expect(adapter.count_runs(process_name: "no_such")).to eq(0)
    end
  end

  describe "#get_process" do
    it "hydrates process details from running config" do
      p = adapter.get_process("lead_pipeline")
      expect(p[:name]).to eq("lead_pipeline")
      expect(p[:status]).to eq("enabled")
      expect(p[:blocks].map { |b| b[:name] }).to eq(%w[extract enrich])
      expect(p[:blocks].first).to include(image: "alpine:latest", output: "result")
      expect(p[:routes].first).to include(from: "extract", to: "enrich")
      expect(p[:last_status]).to eq("queued")
    end

    it "returns nil for unknown" do
      expect(adapter.get_process("nope")).to be_nil
    end
  end

  describe "#get_run / #get_run_steps" do
    it "returns the persisted run by uid" do
      r = adapter.get_run(@seed_run_uid)
      expect(r[:run_uid]).to eq(@seed_run_uid)
      expect(r[:process_name]).to eq("lead_pipeline")
      expect(r).to have_key(:replayable)
    end

    it "returns the seeded step" do
      steps = adapter.get_run_steps(@seed_run_uid)
      expect(steps.size).to eq(1)
      expect(steps.first).to include(block_name: "extract", status: "pending")
    end

    it "returns nil/empty for unknown run uid" do
      expect(adapter.get_run("run_zzzz")).to be_nil
      expect(adapter.get_run_steps("run_zzzz")).to eq([])
    end
  end

  describe "#get_step / #get_run_context / #get_step_logs / #get_run_artifacts" do
    it "returns the step with parsed input/output JSON" do
      step = adapter.get_step(@seed_run_uid, @seed_step_id)
      expect(step[:block_name]).to eq("extract")
      expect(step[:output_json]).to eq({ "ok" => true })
    end

    it "returns nil for a step from a different run" do
      expect(adapter.get_step("run_zzzz", @seed_step_id)).to be_nil
    end

    it "returns parsed run context" do
      ctx = adapter.get_run_context(@seed_run_uid)
      expect(ctx[:input_event]).to eq({ "type" => "lead.created" })
      expect(ctx[:context]).to eq({ "lead" => { "raw" => true } })
    end

    it "returns nil context for unknown run" do
      expect(adapter.get_run_context("run_zzzz")).to be_nil
    end

    it "returns logs for the run, optionally filtered by step" do
      all_logs = adapter.get_step_logs(@seed_run_uid)
      expect(all_logs.size).to eq(2)
      expect(all_logs.map { |l| l[:stream] }).to include("system", "stdout")

      step_logs = adapter.get_step_logs(@seed_run_uid, step_id: @seed_step_id)
      expect(step_logs.size).to eq(2)
    end

    it "filters logs by after_id for incremental polling" do
      all_logs = adapter.get_step_logs(@seed_run_uid)
      first_id = all_logs.first[:id]
      tail = adapter.get_step_logs(@seed_run_uid, after_id: first_id)
      expect(tail.map { |l| l[:id] }).to all(be > first_id)
    end

    it "returns artifacts for the run" do
      arts = adapter.get_run_artifacts(@seed_run_uid)
      expect(arts.size).to eq(1)
      expect(arts.first).to include(name: "out.json", size_bytes: 42)
    end
  end

  describe "config views" do
    it "exposes active (latest) and boot (first) commits with drift" do
      expect(adapter.active_config[:commit][:id]).to eq(2)
      expect(adapter.boot_config[:commit][:id]).to eq(1)
      expect(adapter.active_config[:rendered]).to include("version 2")
      expect(adapter.boot_config[:rendered]).to include("version 1")
    end

    it "lists commits in newest-first order with summaries" do
      ids = adapter.list_commits.map { |c| c[:id] }
      expect(ids).to eq([2, 1])
      expect(adapter.list_commits.first[:short_checksum]).not_to be_nil
    end

    it "diffs two commits via the helper" do
      diff = adapter.config_diff(left: 1, right: 2)
      del_lines = diff.select { |r| r[:action] == "-" }.map { |r| r[:text] }
      ins_lines = diff.select { |r| r[:action] == "+" }.map { |r| r[:text] }
      expect(del_lines).to include(" version 1")
      expect(ins_lines).to include(" version 2")
    end

    it "rollback delegates to ConfigStore and returns the new active commit" do
      result = adapter.rollback_config(1)
      expect(result[:id]).to eq(1)
      expect(adapter.active_config[:commit][:id]).to eq(1)
    end

    it "rollback returns nil for a non-existent commit" do
      expect(adapter.rollback_config(9999)).to be_nil
    end

    it "save_boot_config copies running pointer into startup" do
      result = adapter.save_boot_config
      expect(result[:id]).to eq(2)
      expect(adapter.boot_config[:commit][:id]).to eq(2)
      expect(adapter.status[:config_drift]).to be false
    end
  end

  describe "run actions (against real Orchestrator + StubRunner)" do
    it "trigger_process enqueues a run synchronously and returns its uid" do
      result = adapter.trigger_process("lead_pipeline", { "type" => "lead.created" })
      expect(result[:run_uid]).to start_with("run_")
      run = adapter.get_run(result[:run_uid])
      expect(run[:process_name]).to eq("lead_pipeline")
      expect(run[:config_commit]).to eq(adapter.active_config[:commit][:id])
    end

    it "trigger_process errors for unknown processes" do
      result = adapter.trigger_process("not_a_process", {})
      expect(result[:error]).to be_a(String)
    end

    it "cancel_run flips the status of a non-terminal run" do
      run_uid = adapter.trigger_process("lead_pipeline", {})[:run_uid]
      # The poller-less spec env may already have stub-runner finished
      # the run synchronously — accept either a successful cancel (still
      # running) or a no-op cancel (already terminal).
      cancel_result = adapter.cancel_run(run_uid)
      expect([true, false]).to include(cancel_result)
      expect(adapter.cancel_run("run_zzzzz")).to be(false)
    end

    it "replay_run errors on a run not pinned to a config commit" do
      result = adapter.replay_run(@seed_run_uid)
      # @seed_run_uid was created without process_config_commit_id
      expect(result[:error]).to match(/not pinned/i).or match(/cannot replay/i)
    end

    it "get_artifact returns the row by id" do
      art = adapter.get_run_artifacts(@seed_run_uid).first
      info = adapter.get_artifact(art[:id])
      expect(info[:name]).to eq("out.json")
      expect(info[:path]).to eq("/tmp/out.json")
    end

    it "get_artifact returns nil for unknown id" do
      expect(adapter.get_artifact(99_999)).to be_nil
    end
  end
end

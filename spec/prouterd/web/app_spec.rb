require "spec_helper"

RSpec.describe Prouterd::Web::App do
  include Rack::Test::Methods

  let(:stub) do
    s = Prouterd::Web::Specs::StubCoreApp.new
    seed_demo_stub(s)
    s
  end
  let(:transport) { Prouterd::Web::Specs::RackTestTransport.new(stub) }
  let(:client)    { Prouterd::Web::CoreClient.new(base_url: "http://stub", transport: transport) }
  let(:adapter)   { Prouterd::Web::Adapters::HttpApiAdapter.new(client: client) }
  let(:app)       { Prouterd::Web::App.with_adapter(adapter) }

  describe "GET /" do
    it "redirects to /console" do
      get "/"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/console")
    end
  end

  describe "GET /console" do
    before { get "/console" }

    it "responds 200 OK with HTML" do
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to start_with("text/html")
    end

    it "renders the four console regions" do
      body = last_response.body
      expect(body).to include('class="top-bar"')
      expect(body).to include('class="object-tree"')
      expect(body).to include('class="workspace"')
      expect(body).to include('class="taskbar"')
    end

    it "shows the router name and config drift from the adapter status" do
      expect(last_response.body).to include(adapter.status[:router])
      expect(last_response.body).to match(/drift:\s*yes/)
    end

    it "lists object-tree entries from the spec" do
      %w[Interfaces Routes Processes Runs Config Logs System].each do |label|
        expect(last_response.body).to include(label)
      end
    end
  end

  describe "GET /health" do
    it "returns JSON with web version + adapter class" do
      get "/health"
      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)
      expect(payload["ok"]).to be true
      expect(payload["web_version"]).to eq(Prouterd::Web::VERSION)
      expect(payload["adapter"]).to eq("Prouterd::Web::Adapters::HttpApiAdapter")
    end
  end

  describe "GET /assets/app.css" do
    it "serves the stylesheet" do
      get "/assets/app.css"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to start_with("text/css")
      expect(last_response.body).to include("--bg:")
    end
  end

  describe "GET /assets/window_manager.js" do
    it "serves the window manager script" do
      get "/assets/window_manager.js"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("javascript")
    end
  end

  describe "window content fragments" do
    describe "GET /windows/system" do
      before { get "/windows/system" }

      it "responds 200 OK without the page layout" do
        expect(last_response.status).to eq(200)
        expect(last_response.headers["Content-Type"]).to start_with("text/html")
        expect(last_response.body).not_to include("<!DOCTYPE")
        expect(last_response.body).not_to include("<html")
      end

      it "renders the router name from the adapter status" do
        expect(last_response.body).to include(adapter.status[:router])
        expect(last_response.body).to include('class="kv-table"')
      end
    end

    describe "GET /windows/processes" do
      before { get "/windows/processes" }

      it "renders a process table fragment" do
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('class="data-table"')
        expect(last_response.body).to include("lead_pipeline")
        expect(last_response.body).not_to include("<!DOCTYPE")
      end
    end

    describe "GET /windows/runs" do
      it "renders a runs table fragment" do
        get "/windows/runs"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('class="data-table"')
        expect(last_response.body).to include("run_18492")
        expect(last_response.body).not_to include("<!DOCTYPE")
      end

      it "renders a pagination footer with first / prev / next / last" do
        get "/windows/runs?limit=2&offset=0"
        body = last_response.body
        expect(body).to include('class="pagination"')
        expect(body).to include('data-page-link="/windows/runs?limit=2&offset=0"')  # first
        expect(body).to include('data-page-link="/windows/runs?limit=2&offset=2"')  # next
        expect(body).to include("of 3")  # mock has 3 fixture runs
      end

      it "disables prev/first on the first page and next/last on the last page" do
        get "/windows/runs?limit=2&offset=0"
        # On page 1 the disabled buttons are first/prev; next/last must be enabled.
        expect(last_response.body).to match(/<button[^>]*disabled[^>]*>first/)
        expect(last_response.body).to match(/<button[^>]*disabled[^>]*>prev/)

        get "/windows/runs?limit=2&offset=2"
        # On the last page next/last must be disabled.
        expect(last_response.body).to match(/<button[^>]*disabled[^>]*>next/)
        expect(last_response.body).to match(/<button[^>]*disabled[^>]*>last/)
      end

      it "filters by process and threads the filter through pagination links" do
        get "/windows/runs?limit=10&offset=0&process=lead_pipeline"
        expect(last_response.body).to include("process: lead_pipeline")
        expect(last_response.body).to include("process=lead_pipeline")  # in pagination URLs
      end
    end

    describe "object-tree top-level windows" do
      it "GET /windows/interfaces lists configured interfaces" do
        get "/windows/interfaces"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("leads_in")
      end

      it "GET /windows/interfaces shows direction + plugin-driven fields" do
        get "/windows/interfaces"
        body = last_response.body
        # direction column (Phase 32)
        expect(body).to include("inbound")
        # plugin-driven fields render: webhook path/method, cron schedule
        expect(body).to include("path=/leads")
        expect(body).to include("method=POST")
        expect(body).to include("schedule=*/5 * * * *")
      end

      it "GET /windows/routes lists routes" do
        get "/windows/routes"
        expect(last_response.status).to eq(200)
        # /v1 doesn't expose a separate global-routes list, so the UI flattens
        # process routes only — the per-process `from` → `to` block edges.
        expect(last_response.body).to include('class="data-table"')
        expect(last_response.body).to include("extract")
        expect(last_response.body).to include("enrich")
      end

      it "GET /windows/blocks flattens blocks across processes with process drill-down" do
        get "/windows/blocks"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("extract")
        expect(body).to include('data-open-window="process"')
      end

      it "GET /windows/queues lists queues" do
        get "/windows/queues"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("default")
      end

      it "GET /windows/policies lists retry policies" do
        get "/windows/policies"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("retry_standard")
      end

      it "GET /windows/policies shows retry-when conditions (Phase 25)" do
        get "/windows/policies"
        body = last_response.body
        expect(body).to include("Retry when")
        # the demo policy retries on transient http/timeout errors
        expect(body).to include("error_type")
        expect(body).to include("timeout")
        expect(body).to include("http_status")
      end

      it "GET /windows/secrets shows declared names but no values" do
        get "/windows/secrets"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("CLEARBIT_API_KEY")
        expect(body).to include("Secret values are never displayed")
        # The mock fixture wouldn't have a value to leak anyway, but make
        # sure no `value:` field shows up under any column header.
        expect(body).not_to include(">value<")
      end

      it "GET /windows/logs (no run_uid) renders a run picker for logs" do
        get "/windows/logs"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("pick a run")
        expect(body).to include('data-open-window="logs"')
        expect(body).to include('data-open-resource="run_18492"')
      end

      it "GET /windows/artifacts (no run_uid) renders a run picker for artifacts" do
        get "/windows/artifacts"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include('data-open-window="artifacts"')
      end
    end

    describe "GET /windows/<unknown>" do
      it "falls back to a placeholder fragment that names the type" do
        get "/windows/anything_else"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('class="window-placeholder"')
        expect(last_response.body).to include("anything_else")
        expect(last_response.body).not_to include("<!DOCTYPE")
      end
    end

    describe "GET /windows/process/:name" do
      it "renders Process Inspector with header + tabs for a known process" do
        get "/windows/process/lead_pipeline"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("Process: lead_pipeline")
        expect(body).to include('data-tab="overview"')
        expect(body).to include('data-tab="blocks"')
        expect(body).to include('data-tab="routes"')
        expect(body).to include("extract")
        expect(body).not_to include("<!DOCTYPE")
      end

      it "shows block.interface (post-Phase-23 shape) in the Blocks tab" do
        get "/windows/process/lead_pipeline"
        body = last_response.body
        expect(body).to include("docker extractor")
        expect(body).to include("http salesforce")
        # call_summary derives from call_fields per iface type
        expect(body).to include("ruby /opt/blocks/extract.rb")
        expect(body).to include("POST /leads")
        # secret_names render comma-joined
        expect(body).to include("CLEARBIT_API_KEY")
        expect(body).to include("WEBHOOK_TOKEN")
      end

      it "404s for an unknown process" do
        get "/windows/process/nonexistent"
        expect(last_response.status).to eq(404)
        expect(last_response.body).to include("not found")
      end
    end

    describe "GET /windows/run/:uid" do
      it "renders Run Inspector for a known run" do
        get "/windows/run/run_18492"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("Run: run_18492")
        expect(body).to include('data-tab="summary"')
        expect(body).to include('data-tab="steps"')
        expect(body).to include("notify_sales")
        expect(body).to include("invalid_output")
        expect(body).not_to include("<!DOCTYPE")
      end

      it "404s for an unknown run" do
        get "/windows/run/run_zzzzzz"
        expect(last_response.status).to eq(404)
        expect(last_response.body).to include("not found")
      end
    end

    describe "drill-down rows" do
      it "marks process rows clickable to a process inspector" do
        get "/windows/processes"
        expect(last_response.body).to include('data-open-window="process"')
        expect(last_response.body).to include('data-open-resource="lead_pipeline"')
      end

      it "marks run rows clickable to a run inspector" do
        get "/windows/runs"
        expect(last_response.body).to include('data-open-window="run"')
        expect(last_response.body).to include('data-open-resource="run_18492"')
      end

      it "Run Inspector steps are clickable to a step inspector" do
        get "/windows/run/run_18492"
        expect(last_response.body).to include('data-open-window="step"')
        expect(last_response.body).to include('data-open-resource="run_18492/4"')
      end

      it "Run Inspector exposes quick links to logs / context / artifacts" do
        get "/windows/run/run_18492"
        expect(last_response.body).to include('data-open-window="logs"')
        expect(last_response.body).to include('data-open-window="context"')
        expect(last_response.body).to include('data-open-window="artifacts"')
      end
    end

    describe "GET /windows/logs/:run_uid" do
      it "renders ordered log lines colored by stream" do
        get "/windows/logs/run_18492"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include('class="logs"')
        expect(body).to include("logs__line--system")
        expect(body).to include("logs__line--stdout")
        expect(body).to include("logs__line--stderr")
        expect(body).to include("invalid_output")
      end

      it "filters by step when ?step= is provided" do
        get "/windows/logs/run_18492?step=4"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("invalid_output")
        # step 1 messages should be excluded
        expect(last_response.body).not_to include("parsed event body")
      end
    end

    describe "GET /windows/context/:run_uid" do
      it "renders a JSON tree with both context and input event tabs" do
        get "/windows/context/run_18492"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include('data-tab="context"')
        expect(body).to include('data-tab="event"')
        expect(body).to include("Acme Inc")          # nested string from context
        expect(body).to include("class=\"json__")    # tree markup
      end

      it "redacts sensitive keys (Authorization, etc.) when rendering input events" do
        stub.runs["run_redact"] = {
          uid: "run_redact", process_name: "lead_pipeline", status: "success",
          input_event_json: '{"headers":{"Authorization":"Bearer SUPERSECRET","x-trace":"ok"}}',
          context_json: "{}",
          steps: []
        }

        get "/windows/context/run_redact"
        expect(last_response.status).to eq(200)
        expect(last_response.body).not_to include("SUPERSECRET")
        expect(last_response.body).to include("[REDACTED]")
      end

      it "404s for unknown runs" do
        get "/windows/context/run_zzz"
        expect(last_response.status).to eq(404)
      end
    end

    describe "GET /windows/artifacts/:run_uid" do
      it "renders the artifacts table with size formatting" do
        get "/windows/artifacts/run_18491"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("lead_raw.json")
        expect(last_response.body).to include("47 B")
      end
    end

    describe "GET /windows/step/:run_uid/:step_id" do
      it "renders a step inspector with input / output / logs / artifacts tabs" do
        get "/windows/step/run_18492/4"
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include("Step 4")
        expect(body).to include("notify_sales")
        expect(body).to include('data-tab="input"')
        expect(body).to include('data-tab="output"')
        expect(body).to include('data-tab="logs"')
        expect(body).to include('data-tab="artifacts"')
        expect(body).to include("expected JSON object")  # error_message in Output tab
      end

      it "404s for unknown step" do
        get "/windows/step/run_18492/9999"
        expect(last_response.status).to eq(404)
      end
    end

    describe "GET /windows/config" do
      before { get "/windows/config" }

      it "renders the multi-tab config window" do
        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include('data-tab="active"')
        expect(body).to include('data-tab="boot"')
        expect(body).to include('data-tab="draft"')
        expect(body).to include('data-tab="diff"')
        expect(body).to include('data-tab="commits"')
        expect(body).to include("router sales_ops")          # rendered config
        expect(body).to include("class=\"diff\"")            # active vs boot diff
        expect(body).to include("diff__row--del")            # at least one removed line
        expect(body).to include("diff__row--ins")            # at least one inserted line
      end

      it "lists commits and exposes rollback / diff actions for non-active rows" do
        body = last_response.body
        expect(body).to include('data-config-action="rollback"')
        expect(body).to include('data-open-window="diff"')
        expect(body).to include('data-config-action="save-boot"')  # drift in mock
      end
    end

    describe "GET /windows/diff/:left/:right" do
      it "renders a standalone diff window between two commits" do
        get "/windows/diff/39/42"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Diff: #39 → #42")
        expect(last_response.body).to include("class=\"diff\"")
      end

      it "404s for unknown commits" do
        get "/windows/diff/9999/8888"
        expect(last_response.status).to eq(404)
      end
    end

    describe "POST /actions/config/rollback/:commit_id" do
      it "rolls back to a known commit and clears drift" do
        post "/actions/config/rollback/39"
        expect(last_response.status).to eq(200)
        payload = JSON.parse(last_response.body)
        expect(payload["ok"]).to be true
        expect(payload["active_commit"]).to eq(39)

        # status now reflects no drift
        get "/health"
        get "/windows/system"
        expect(last_response.body).to match(/Active config[^\d]+#39/m)
      end

      it "400s on unknown commit" do
        post "/actions/config/rollback/9999"
        expect(last_response.status).to eq(400)
      end
    end

    describe "POST /actions/config/save-boot" do
      it "writes running pointer to boot pointer and clears drift" do
        post "/actions/config/save-boot"
        expect(last_response.status).to eq(200)
        payload = JSON.parse(last_response.body)
        expect(payload["ok"]).to be true
        expect(payload["boot_commit"]).to eq(42)
      end
    end
  end

  describe "console workspace shell" do
    before { get "/console" }

    it "exposes a workspace host that the window manager can mount into" do
      expect(last_response.body).to include('id="workspace"')
      expect(last_response.body).to include('id="workspace-placeholder"')
    end

    it "exposes taskbar slots and the reset button" do
      expect(last_response.body).to include('id="taskbar-entries"')
      expect(last_response.body).to include('id="taskbar-empty"')
      expect(last_response.body).to include('id="reset-workspace-btn"')
    end
  end

  describe "GET /windows/trace" do
    it "renders the trace event form" do
      get "/windows/trace"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Trace event")
      expect(last_response.body).to include('data-trace-event')
      expect(last_response.body).to include('data-trace-action="trace"')
    end
  end

  describe "POST /actions/trace" do
    it "calls adapter.trace_event and wraps the result" do
      allow(adapter).to receive(:trace_event).with(
        { "type" => "lead.created" }, interface_name: "leads_in"
      ).and_return("process" => "lead_pipeline", "graph" => [])

      post "/actions/trace",
        JSON.dump(event: { "type" => "lead.created" }, interface_name: "leads_in"),
        { "CONTENT_TYPE" => "application/json" }

      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)
      expect(payload["ok"]).to be true
      expect(payload["data"]["process"]).to eq("lead_pipeline")
    end

    it "400s on adapter error result" do
      allow(adapter).to receive(:trace_event).and_return(error: "no such interface")

      post "/actions/trace", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)["error"]).to eq("no such interface")
    end
  end

  describe "POST /actions/runs/trigger/:process_name" do
    it "creates a new run and returns its uid" do
      post "/actions/runs/trigger/lead_pipeline",
        JSON.dump(input_event: { "type" => "lead.created" }),
        { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)
      expect(payload["ok"]).to be true
      expect(payload["run_uid"]).to start_with("run_")
    end

    it "400s for unknown process" do
      post "/actions/runs/trigger/no_such_proc", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(400)
    end
  end

  describe "POST /actions/runs/replay/:uid" do
    it "creates a replay run linked to the original" do
      post "/actions/runs/replay/run_18492", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)
      expect(payload["ok"]).to be true
      expect(payload["replay_of"]).to eq("run_18492")
      expect(payload["run_uid"]).to start_with("run_")
    end

    it "supports from_block to start the replay at a specific step" do
      post "/actions/runs/replay/run_18492", JSON.dump(from_block: "score"),
        { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(200)
      payload = JSON.parse(last_response.body)
      expect(payload["from_block"]).to eq("score")
    end

    it "404s for unknown run" do
      post "/actions/runs/replay/run_zzzz", "{}", { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /actions/runs/cancel/:uid" do
    it "cancels a non-terminal run" do
      post "/actions/runs/trigger/lead_pipeline", "{}", { "CONTENT_TYPE" => "application/json" }
      uid = JSON.parse(last_response.body)["run_uid"]

      post "/actions/runs/cancel/#{uid}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["ok"]).to be true
    end

    it "400s for unknown run" do
      post "/actions/runs/cancel/run_zzzz"
      expect(last_response.status).to eq(400)
    end

    it "400s for already-terminal run" do
      # run_18491 is success in fixtures
      post "/actions/runs/cancel/run_18491"
      expect(last_response.status).to eq(400)
    end
  end

  describe "GET /artifacts/:id/download" do
    it "404s when the adapter returns nil (mock has no real bytes)" do
      get "/artifacts/1/download"
      expect(last_response.status).to eq(404)
    end
  end

  describe "drill-down + actions surface in inspector views" do
    it "Run Inspector for a non-terminal run shows the cancel button" do
      post "/actions/runs/trigger/lead_pipeline", "{}", { "CONTENT_TYPE" => "application/json" }
      uid = JSON.parse(last_response.body)["run_uid"]
      get "/windows/run/#{uid}"
      expect(last_response.body).to include('data-run-action="cancel"')
    end

    it "Step Inspector exposes a 'replay from this step' action" do
      get "/windows/step/run_18492/4"
      expect(last_response.body).to include('data-run-action="replay-from"')
      expect(last_response.body).to include('data-from-block="notify_sales"')
    end

    it "Process Inspector has the Trigger tab with a JSON textarea" do
      get "/windows/process/lead_pipeline"
      body = last_response.body
      expect(body).to include('data-tab="trigger"')
      expect(body).to include('data-trigger-process="lead_pipeline"')
      expect(body).to include('class="trigger-form__input"')
    end

    it "Artifacts table includes download links" do
      get "/windows/artifacts/run_18491"
      expect(last_response.body).to include("/artifacts/1/download")
    end
  end

  describe "GET /windows/cli/:session_id" do
    it "renders a CLI window shell with prompt and input" do
      get "/windows/cli/sess-1"
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).to include('class="cli"')
      expect(body).to include('data-cli-session="sess-1"')
      expect(body).to include('class="cli__input"')
      expect(body).to include('class="cli__prompt"')
      expect(body).not_to include("<!DOCTYPE")
    end
  end

  describe "GET /ws (without WebSocket upgrade headers)" do
    it "rejects with 426 and a hint" do
      get "/ws"
      expect(last_response.status).to eq(426)
      expect(last_response.body).to include("WebSocket upgrade required")
    end
  end

  context "when no adapter has been bound" do
    let(:app) { Prouterd::Web::App }

    it "returns 500 with a clear error" do
      get "/console"
      expect(last_response.status).to eq(500)
      expect(last_response.body).to include("no adapter configured")
    end
  end
end

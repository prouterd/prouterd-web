module Prouterd
  module Web
    module Specs
      # Helpers for app-level specs: builds a fully wired Prouterd::Web::App
      # subclass against a programmable StubCoreApp, with optional auth and
      # an injectable cli_bridge.
      module SpecAppBuilder
        # Returns an [app, stub, adapter] triple. The stub is mutable so
        # specs configure fixture state via attr accessors before the
        # request is fired.
        def build_app_against_stub(token: nil, cli_bridge: nil, auth_token: nil)
          stub      = StubCoreApp.new
          transport = RackTestTransport.new(stub)
          client    = Prouterd::Web::CoreClient.new(base_url: "http://stub", token: token, transport: transport)
          adapter   = Prouterd::Web::Adapters::HttpApiAdapter.new(client: client)
          app       = Prouterd::Web::App.with_adapter(
            adapter,
            auth_token: auth_token,
            cli_bridge: cli_bridge
          )
          [app, stub, adapter]
        end

        # Pre-populates the StubCoreApp with the standard "demo" fixture set
        # — the same shape MockAdapter used to hard-code, but mutable per test.
        def seed_demo_stub(stub)
          stub.status_payload = {
            "version" => "0.1.0", "router" => "sales_ops",
            "running_commit" => 42, "startup_commit" => 39,
            "interfaces" => 3, "processes" => 3, "accepting" => true,
            "in_flight" => 2
          }
          stub.processes = [
            {
              name: "lead_pipeline", description: "Lead enrichment and sales notification",
              queue: "default", shutdown: false,
              blocks: [
                { name: "extract",      image: "registry.local/blocks/extract-lead:v1",
                  input: "event.body", output: "lead.raw", timeout_ms: 30_000,
                  retry_policy: nil, shutdown: false },
                { name: "enrich",       image: "registry.local/blocks/enrich-lead:v3",
                  input: "lead.raw",   output: "lead.enriched", timeout_ms: 120_000,
                  retry_policy: "retry_standard", shutdown: false },
                { name: "score",        image: "registry.local/blocks/score-lead:v2",
                  input: "lead.enriched", output: "lead.scored", timeout_ms: 20_000,
                  retry_policy: nil,   shutdown: false },
                { name: "notify_sales", image: "registry.local/blocks/notify-sales:v1",
                  input: "lead.scored", output: "notification.result", timeout_ms: 15_000,
                  retry_policy: nil,   shutdown: false }
              ],
              routes: [
                { from: "extract", to: "enrich",       matches: [], on_failure: "stop", shutdown: false },
                { from: "enrich",  to: "score",        matches: [], on_failure: "stop", shutdown: false },
                { from: "score",   to: "notify_sales",
                  matches: [{ path: "lead.scored.score", operator: "gt", values: [70] }],
                  on_failure: "stop", shutdown: false }
              ]
            },
            {
              name: "billing_recover", description: "Recover failed billing webhooks",
              queue: "high", shutdown: false,
              blocks: [], routes: []
            }
          ]
          stub.interfaces = [
            { name: "leads_in",     type: "webhook", shutdown: false },
            { name: "billing_evt",  type: "queue",   shutdown: false },
            { name: "support_chat", type: "webhook", shutdown: true  }
          ]
          stub.queues = [
            { name: "default", concurrency: 10, timeout_ms: 600_000 },
            { name: "high",    concurrency:  4, timeout_ms: 300_000 }
          ]
          stub.policies = [
            { name: "retry_standard", retry_attempts: 3, retry_backoff: "exponential",
              retry_initial_delay_ms: 5_000, retry_max_delay_ms: 120_000, timeout_ms: nil }
          ]
          stub.secrets = [
            { name: "WEBHOOK_TOKEN",    source_type: "env", source_ref: "WEBHOOK_TOKEN",
              used_by: ["interface leads_in"], status: "missing" },
            { name: "CLEARBIT_API_KEY", source_type: "env", source_ref: "CLEARBIT_API_KEY",
              used_by: ["block enrich"],       status: "missing" }
          ]
          stub.commits = [
            { id: 42, checksum: "sha256:c4f2a90b8e1f", author: "carol",
              message: "bump score threshold to 80",  created_at: "2026-05-02T12:00:00Z",
              rendered_config: "router sales_ops\n version 2\n route X if Y gt 80\nexit\n" },
            { id: 39, checksum: "sha256:91003fde7720", author: "alice",
              message: "initial commit",                created_at: "2026-04-30T09:00:00Z",
              rendered_config: "router sales_ops\n version 1\n route X if Y gt 70\nexit\n" }
          ]
          stub.running_commit_id   = 42
          stub.startup_commit_id   = 39
          stub.running_config_text = "router sales_ops\n version 2\nexit\n"
          stub.startup_config_text = "router sales_ops\n version 1\nexit\n"

          # Seed three runs with the canonical IDs the suite refers to.
          stub.runs = {
            "run_18492" => {
              uid: "run_18492", process_name: "lead_pipeline",
              interface_name: "leads_in", status: "failed",
              commit_id: 42, replay_of: nil,
              duration_ms: 18_200,
              started_at: "2026-05-02T14:12:44Z", finished_at: "2026-05-02T14:13:02Z",
              created_at: "2026-05-02T14:12:43Z",
              input_event_json: '{"type":"lead.created","body":{"email":"carol@acme.com"}}',
              context_json: '{"lead":{"raw":{"email":"carol@acme.com"},"enriched":{"company":{"name":"Acme Inc","size":120}},"scored":{"score":82}}}',
              error_summary: "block notify_sales failed: invalid_output",
              steps: [
                { id: 1, block_name: "extract",      status: "success", attempt: 1,
                  image: "registry.local/blocks/extract-lead:v1",
                  exit_code: 0, duration_ms: 1_200,
                  input_json: '{"a":1}', output_json: '{"b":2}',
                  started_at: "2026-05-02T14:12:44Z", finished_at: "2026-05-02T14:12:45Z" },
                { id: 2, block_name: "enrich",       status: "success", attempt: 1,
                  image: "registry.local/blocks/enrich-lead:v3",
                  exit_code: 0, duration_ms: 4_800 },
                { id: 3, block_name: "score",        status: "success", attempt: 1,
                  image: "registry.local/blocks/score-lead:v2",
                  exit_code: 0, duration_ms: 700 },
                { id: 4, block_name: "notify_sales", status: "failed",  attempt: 1,
                  image: "registry.local/blocks/notify-sales:v1",
                  exit_code: 1, duration_ms: 12_000,
                  error_type: "invalid_output",
                  error_message: "expected JSON object" }
              ]
            },
            "run_18491" => {
              uid: "run_18491", process_name: "lead_pipeline",
              interface_name: "leads_in", status: "success",
              commit_id: 42, replay_of: nil, duration_ms: 6_800,
              started_at: "2026-05-02T14:09:11Z", finished_at: "2026-05-02T14:09:18Z",
              steps: []
            },
            "run_18490" => {
              uid: "run_18490", process_name: "billing_recover",
              interface_name: nil, status: "success",
              commit_id: 42, replay_of: nil, duration_ms: 12_400,
              started_at: "2026-05-02T14:02:33Z", finished_at: "2026-05-02T14:02:45Z",
              steps: []
            }
          }
          stub.run_logs["run_18492"] = [
            { id: 11, run_id: 1, step_id: 4, stream: "system", content: "starting container",                 created_at: "2026-05-02T14:12:55Z" },
            { id: 12, run_id: 1, step_id: 4, stream: "stdout", content: "POST /webhook ...",                  created_at: "2026-05-02T14:12:56Z" },
            { id: 13, run_id: 1, step_id: 4, stream: "stderr", content: "expected JSON object, got string",   created_at: "2026-05-02T14:13:01Z" },
            { id: 14, run_id: 1, step_id: 4, stream: "system", content: "block failed: invalid_output",       created_at: "2026-05-02T14:13:02Z" },
            { id:  9, run_id: 1, step_id: 1, stream: "stdout", content: "parsed event body",                  created_at: "2026-05-02T14:12:44Z" }
          ]
          stub.run_artifacts["run_18491"] = [
            { id: 1, step_id: 5, block_name: "extract", name: "lead_raw.json",
              size_bytes: 47, content_type: "application/json", checksum: "sha256:aa11",
              created_at: "2026-05-02T14:09:12Z" }
          ]
          stub.trace_payload = {
            global_route_passes: true,
            process: "lead_pipeline",
            graph: [
              { block: "extract", depends_on: nil },
              { block: "enrich",  depends_on: "extract" }
            ],
            warnings: []
          }
          stub
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include(Prouterd::Web::Specs::SpecAppBuilder)
end

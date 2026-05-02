require "prouterd/web"

# Adapter mode selection (in priority order):
#   1. PROUTERD_CORE_URL set      → HttpApiAdapter (production-shape)
#   2. PROUTERD_DB set            → SqliteAdapter  (single-machine)
#   3. otherwise                 → MockAdapter    (offline UI dev)
#
# CLI bridge / events consumer wiring lives in exe/prouterd-web; this
# config.ru is the bare-minimum for `rackup` and the rspec smoke.

adapter =
  if ENV["PROUTERD_CORE_URL"]
    client = Prouterd::Web::CoreClient.new(
      base_url: ENV["PROUTERD_CORE_URL"],
      token:    ENV["PROUTERD_CORE_TOKEN"]
    )
    Prouterd::Web::Adapters::HttpApiAdapter.new(client: client)
  elsif ENV["PROUTERD_DB"]
    Prouterd::Web::Adapters::SqliteAdapter.new(db_path: ENV["PROUTERD_DB"])
  else
    Prouterd::Web::Adapters::MockAdapter.new
  end

run Prouterd::Web::App.with_adapter(adapter, auth_token: ENV["PROUTERD_WEB_ADMIN_TOKEN"])

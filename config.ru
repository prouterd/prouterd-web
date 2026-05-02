require "prouterd/web"

# Required: PROUTERD_CORE_URL pointing at an prouterd daemon's /v1.
core_url = ENV["PROUTERD_CORE_URL"] or raise "set PROUTERD_CORE_URL"
client   = Prouterd::Web::CoreClient.new(base_url: core_url, token: ENV["PROUTERD_CORE_TOKEN"])
adapter  = Prouterd::Web::Adapters::HttpApiAdapter.new(client: client)

# config.ru is the bare-minimum mount; live events / CLI bridge wiring
# lives in exe/prouterd-web. This file works for `rackup` smokes and the
# spec suite — neither needs the WS plumbing.
run Prouterd::Web::App.with_adapter(adapter, auth_token: ENV["PROUTERD_WEB_ADMIN_TOKEN"])

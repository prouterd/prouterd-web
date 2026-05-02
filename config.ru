require "prouterd/web"

adapter =
  if ENV["PROUTERD_DB"]
    Prouterd::Web::Adapters::SqliteAdapter.new(db_path: ENV["PROUTERD_DB"])
  else
    Prouterd::Web::Adapters::MockAdapter.new
  end

run Prouterd::Web::App.with_adapter(adapter, auth_token: ENV["PROUTERD_WEB_ADMIN_TOKEN"])

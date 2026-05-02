require "prouterd"

require_relative "web/version"
require_relative "web/helpers/json_tree"
require_relative "web/helpers/config_diff"
require_relative "web/helpers/redactor"
require_relative "web/core_adapter"
require_relative "web/adapters/mock_adapter"
require_relative "web/adapters/sqlite_adapter"
require_relative "web/broadcaster"
require_relative "web/poller"
require_relative "web/websocket_connection"
require_relative "web/app"

module Prouterd
  module Web
  end
end

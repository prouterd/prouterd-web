require_relative "lib/prouterd/web/version"

Gem::Specification.new do |spec|
  spec.name        = "prouterd-web"
  spec.version     = Prouterd::Web::VERSION
  spec.authors     = ["Prouterd Authors"]
  spec.summary     = "Process Router Web Console"
  spec.description = "Operator console for the Prouterd Process Router: object tree, " \
                     "draggable windows, run inspector, embedded CLI, live updates over WebSocket. " \
                     "Connects to a running Prouterd core in-process via CoreAdapter."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.glob("{lib,exe}/**/*").select { |f| File.file?(f) }
  spec.files += %w[prouterd-web.gemspec config.ru Rakefile].select { |f| File.file?(f) }
  spec.bindir      = "exe"
  spec.executables = ["prouterd-web"]
  spec.require_paths = ["lib"]

  # The console talks to the prouterd daemon over HTTP /v1 + WS /v1/events
  # /v1/cli — no Ruby gem coupling. Install on a separate host and point
  # at the daemon with `prouterd-web --core-url`.
  spec.add_dependency "roda",    "~> 3.85"
  spec.add_dependency "rack",    "~> 3.0"
  spec.add_dependency "rackup",  "~> 2.1"
  spec.add_dependency "erubi",   "~> 1.13"
  spec.add_dependency "tilt",    "~> 2.4"
  spec.add_dependency "puma",    "~> 6.0"
  spec.add_dependency "diff-lcs",      "~> 1.5"
  spec.add_dependency "faye-websocket", "~> 0.11"

  spec.add_development_dependency "rspec",     "~> 3.13"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rake",      "~> 13.2"
end

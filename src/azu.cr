require "http"
require "log"
require "radix"
require "json"
require "xml"
require "colorize"
require "schema"
require "crinja"
require "./azu/routable"
require "./azu/router"
require "./azu/router/**"
require "./azu/cache"
require "./azu/performance_metrics"
require "./azu/query_store"
require "./azu/request_context"
require "./azu/development_tools"
require "./azu/performance_reporter"
require "./azu/*"
require "./azu/channel/**"
require "./azu/components/**"
require "./azu/handler/**"
require "./azu/helpers/**"
require "./azu/pub_sub/**"
require "./azu/spark/**"
require "./azu/templates/**"

# Not globbed on purpose: `azu/cql` is opt-in and needs the cql shard. Add every new core directory above; spec/azu/opt_in_integrations_spec.cr
# fails when one is missing.

module Azu
  alias Validator = Schema::Validator
  CONFIG = Configuration.new

  # Fiber-local configuration storage for testing and isolation
  @@fiber_configs = {} of Fiber => Configuration
  @@config_mutex = Mutex.new

  # Get the current configuration
  #
  # Returns fiber-local configuration if set, otherwise returns the global CONFIG.
  # This allows tests to run with isolated configurations without affecting
  # other fibers or the global state.
  #
  # Example:
  # ```
  # # Get current config
  # current = Azu.current_config
  # puts current.env # => "development"
  # ```
  def self.current_config : Configuration
    @@config_mutex.synchronize do
      @@fiber_configs[Fiber.current]? || CONFIG
    end
  end

  # Execute a block with a custom configuration
  #
  # This is primarily useful for testing, allowing tests to run with
  # isolated configuration without affecting other tests or the global state.
  #
  # Example:
  # ```
  # test_config = Azu::Configuration.new
  # test_config.env = Azu::Environment::Test
  #
  # Azu.with_config(test_config) do
  #   # Code here uses test_config
  #   Azu.current_config.env # => Environment::Test
  # end
  # # Outside the block, the configuration that was current before is current again
  # ```
  #
  # Scopes nest: leaving an inner one restores the outer configuration, or the global one when
  # there was none.
  def self.with_config(config : Configuration, &)
    fiber = Fiber.current
    previous = @@config_mutex.synchronize do
      @@fiber_configs[fiber]?.tap { @@fiber_configs[fiber] = config }
    end
    begin
      yield
    ensure
      @@config_mutex.synchronize do
        if previous
          @@fiber_configs[fiber] = previous
        else
          @@fiber_configs.delete(fiber)
        end
      end
    end
  end

  # Like `spawn`, but the new fiber sees the configuration that is current in the fiber that spawns
  # it. A plain `spawn` starts with the global configuration, so work that outlives the request
  # (timers, WebSocket heartbeats) must spawn through this to keep the app it belongs to.
  def self.spawn_scoped(name : String? = nil, &block : ->) : Fiber
    config = current_config
    spawn(name: name) { with_config(config, &block) }
  end

  # The path of `endpoint` in the app being served, with the prefix that app is mounted at. Links
  # use it so the same endpoint answers with the right URL wherever it is mounted. `fallback`
  # is returned as it is when the current router does not route the endpoint: the endpoint belongs
  # to another app, whose prefix this one does not know.
  def self.mounted_path(endpoint : Routable.class, fallback : String = "") : String
    router = current_config.router
    (path = router.path_of(endpoint)) ? router.mount_prefix + path : fallback
  end

  # Clear all fiber-local configurations
  #
  # Useful for cleanup in test suites.
  def self.clear_fiber_configs : Nil
    @@config_mutex.synchronize do
      @@fiber_configs.clear
    end
  end

  # Rails-like cache API
  def self.cache
    current_config.cache
  end

  # Installs Azu's log format and a Debug level for the whole process. Opt in by calling it once at
  # boot; neither requiring azu nor `start` does it, so an app that sets up `Log` itself keeps its
  # own backend and level.
  def self.setup_logging : Nil
    Log.setup(:debug, Log::IOBackend.new(formatter: LogFormat))
  end

  # Starts the parts that need a running app: the async log pipeline, the development tools and
  # upload cleanup. `start` calls this. It never touches `Log`.
  def self.prepare : Nil
    AsyncLogging.initialize
    CONFIG.prepare
  end

  # Stops the long lived parts of the framework: closes Spark connections and the PubSub backend.
  # Called by `start` once the server stops; safe to call again.
  def self.shutdown : Nil
    Spark.shutdown
    PubSub.shutdown
  end

  macro included
    def self.configure(&)
      with CONFIG yield CONFIG
    end

    def self.log
      CONFIG.log
    end

    def self.env
      CONFIG.env
    end

    def self.config
      CONFIG
    end

    # Starts with `Azu::App#default_handlers`. Pass an array to choose the handlers yourself: it is
    # used exactly as given and nothing is added to it.
    def self.start
      start Azu::App.default.default_handlers
    end

    def self.start(handlers : Array(HTTP::Handler))
      Azu.prepare
      config.handlers = handlers.map(&.as(HTTP::Handler))
      server = Azu::App.default.server(handlers)

      if config.tls?
        server.bind_tls config.host, config.port, config.tls, config.port_reuse?
      else
        server.bind_tcp config.host, config.port, config.port_reuse?
      end

      {% for signal in [:INT, :TERM] %}
        Signal::{{ signal.id }}.trap do
          Signal::{{ signal.id }}.reset
          log.info { "Shutting down server" }
          server.close
        end
      {% end %}

      begin
        log.info { server_info }
        server.listen
      rescue e
        log.error(exception: e) { "Server failed to start!" }
      end

      app = Azu::App.default
      log.info { "Waiting for requests in flight" }
      log.warn { "Shutdown timeout: requests still in flight were dropped" } unless app.drain
      Azu.shutdown
    end

    private def self.server_info(time = Time.instant)
      String.build do |s|
        s << "Server started at #{Time.local.to_s("%a %m/%d/%Y %I:%M:%S")}.".colorize(:white).underline
        s << "\n   ⤑  Environment: ".colorize(:white)
        s << env.colorize(:light_blue)
        s << "\n   ⤑  Host: ".colorize(:white)
        s << config.host.colorize(:light_blue)
        s << "\n   ⤑  Port: ".colorize(:white)
        s << config.port.colorize(:light_blue)
        s << "\n   ⤑  Startup Time: ".colorize(:white)
        s << (Time.instant - time).total_milliseconds
        s << " millis".colorize(:white)
      end
    end
  end
end

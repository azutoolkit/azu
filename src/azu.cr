require "http"
require "log"
require "json"
require "xml"
require "colorize"
require "schema"
require "crinja"
require "./azu/env"
require "./azu/clock"
require "./azu/redis"
require "./azu/version"
require "./azu/routable"
require "./azu/router"
require "./azu/router/**"
require "./azu/cache"
require "./azu/declared_endpoints"
require "./azu/instrumentation"
require "./azu/query_store"
require "./azu/request_context"
require "./azu/*"
require "./azu/response/**"
require "./azu/openapi/**"
require "./azu/channel/**"
require "./azu/handler/**"
require "./azu/helpers/**"
require "./azu/presence/**"
require "./azu/redis/**"
require "./azu/pub_sub/**"
require "./azu/spark/**"
require "./azu/templates/**"
require "./azu/exception_page/**"
require "./azu/ui/**"

class Fiber
  # :nodoc:
  property azu_scope : Azu::FiberScope?
  # :nodoc:
  property azu_config_generation : UInt64 = 0_u64
end

# Not globbed on purpose: `azu/cql` is opt-in and needs the cql shard, `azu/dev` is the opt-in dashboard and
# performance tooling. Add every new core directory above; spec/azu/opt_in_integrations_spec.cr fails when one is
# missing.

module Azu
  # The release version, read from shard.yml at compile time so the bot's version bump is the only edit.
  VERSION = shard_version({{ read_file("#{__DIR__}/../shard.yml") }})

  alias Validator = Schema::Validator
  CONFIG = Configuration.new

  # :nodoc:
  # Value stored on the owning fiber. A snapshot restores both fields when a scope exits.
  struct FiberScope
    getter app : App?
    getter config : Configuration?

    def initialize(@app : App? = nil, @config : Configuration? = nil)
    end

    def with_app(app : App) : FiberScope
      FiberScope.new(app, @config)
    end

    def with_config(config : Configuration) : FiberScope
      FiberScope.new(@app, config)
    end
  end

  # Invalidates configurations for the test cleanup API without retaining every active fiber.
  # Normal requests only read this counter; clearing is never part of request dispatch.
  @@config_generation = Atomic(UInt64).new(0_u64)

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
    fiber_scope(Fiber.current).try(&.config) || CONFIG
  end

  # Whether this process runs in a strict environment (`Azu::Env.strict_environments`: production and staging by
  # default): the one taken from `CRYSTAL_ENV`, or the one the current configuration holds (an app that sets
  # `config.env = Production` in code is strict too). What `Handler::CSRF` and `Spark` ask before they accept a
  # random fallback for a missing secret, and what `App#start` asks before it checks `Env.required_at_boot`.
  def self.strict_environment? : Bool
    current_config.strict_environment?
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
    previous = enter_scope(fiber, &.with_config(config))
    begin
      yield
    ensure
      leave_scope(fiber, previous)
    end
  end

  # :nodoc:
  #
  # `with_app(app) { with_config(config) { ... } }` with one fiber-local write on the way in and one on
  # the way out, which is what serving a request does.
  def self.with_scope(app : App?, config : Configuration, &)
    fiber = Fiber.current
    previous = enter_scope(fiber) { |scope| app ? scope.with_app(app).with_config(config) : scope.with_config(config) }
    begin
      yield
    ensure
      leave_scope(fiber, previous)
    end
  end

  # Replaces the fiber's record with what the block makes of it and returns the one that was there.
  private def self.enter_scope(fiber : Fiber, & : FiberScope -> FiberScope) : FiberScope?
    previous = fiber_scope(fiber)
    fiber.azu_scope = yield(previous || FiberScope.new)
    previous
  end

  private def self.leave_scope(fiber : Fiber, previous : FiberScope?) : Nil
    # As with the former registry, an enclosing scope's saved snapshot survives a clear.
    fiber.azu_config_generation = @@config_generation.get
    fiber.azu_scope = previous
  end

  private def self.fiber_scope(fiber : Fiber) : FiberScope?
    generation = @@config_generation.get
    if fiber.azu_config_generation != generation
      fiber.azu_scope = fiber.azu_scope.try { |scope| FiberScope.new(scope.app) }
      fiber.azu_config_generation = generation
    end
    fiber.azu_scope
  end

  # Like `spawn`, but the new fiber sees the configuration that is current in the fiber that spawns
  # it. A plain `spawn` starts with the global configuration, so work that outlives the request
  # (timers, WebSocket heartbeats) must spawn through this to keep the app it belongs to.
  def self.spawn_scoped(name : String? = nil, &block : ->) : Fiber
    config = current_config
    app = current_app
    spawn(name: name) { with_app(app) { with_config(config, &block) } }
  end

  # The app serving the request this fiber is handling (or the fiber spawned by `spawn_scoped` from
  # it); nil outside one. A mounted app's requests belong to the app that owns the server.
  def self.current_app : App?
    Fiber.current.azu_scope.try(&.app)
  end

  # Runs the block with `app` as the current app of this fiber. A nil `app` leaves things as they are.
  def self.with_app(app : App?, &)
    return yield unless app
    fiber = Fiber.current
    previous = enter_scope(fiber, &.with_app(app))
    begin
      yield
    ensure
      leave_scope(fiber, previous)
    end
  end

  # True once the app serving this request has begun shutting down (SIGTERM, SIGINT or
  # `App#begin_shutdown`). A long-lived response (SSE, long polling) polls this, or waits on
  # `shutdown_signal`, and finishes so the drain does not wait for it until `shutdown_timeout`.
  def self.shutting_down? : Bool
    current_app.try(&.draining?) || false
  end

  # A channel that is closed when the app serving this request begins shutting down, for
  # `select when Azu.shutdown_signal.receive?`. Outside an app it never closes.
  def self.shutdown_signal : ::Channel(Nil)
    current_app.try(&.shutdown_signal) || ::Channel(Nil).new
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
  # Useful for cleanup in test suites. Invalidated configurations are released on the
  # owning fiber's next configuration lookup or scope exit; apps remain unchanged.
  def self.clear_fiber_configs : Nil
    @@config_generation.add(1_u64)
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
    App.default.prepare
  end

  @@shutdown_hooks = [] of Proc(Nil)
  @@shutdown_hooks_mutex = Mutex.new

  # Registers work for `Azu.shutdown`: it runs after the PubSub backend has stopped and before the shared
  # Redis pools close. Hooks run in reverse registration order, like `at_exit`, so a hook an app registers
  # (flushing a queue through the database, say) runs before the database pools that `azu/cql` registered
  # when it was required are closed. Optional subsystems that core does not require use it. A hook that raises
  # is logged and does not stop the others. Handler fibers still serving a request when the server stops
  # can meet a closed pool, as they can a closed Redis pool.
  def self.on_shutdown(&block : ->) : Nil
    @@shutdown_hooks_mutex.synchronize { @@shutdown_hooks << block }
  end

  # Stops the long lived parts of the framework: closes Spark connections, the default presence tracker
  # (so its entries leave before the PubSub backend stops), the PubSub backend, whatever was registered with
  # `on_shutdown` (such as database pools), the shared Redis pools those used and, last, the async log
  # pipeline, which writes every entry it still holds (the others' included) before this returns.
  # Called by `start` once the server stops; safe to call again.
  def self.shutdown : Nil
    Spark.shutdown
    Presence.shutdown
    PubSub.shutdown
    run_shutdown_hooks
    Redis.shutdown
    AsyncLogging.shutdown
  end

  private def self.run_shutdown_hooks : Nil
    hooks = @@shutdown_hooks_mutex.synchronize { @@shutdown_hooks.dup }
    hooks.reverse_each do |hook|
      hook.call
    rescue ex
      ::Log.for("azu.shutdown").error(exception: ex) { "a shutdown hook failed" }
    end
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

    # Serves `Azu::App.default` with `Azu::App#default_handlers` until SIGINT or SIGTERM: `Azu::App#start`.
    def self.start
      Azu::App.default.start
    end

    # Pass an array to choose the handlers yourself: it is used exactly as given and nothing is added to it.
    # With `defaults: true` it is placed inside the default stack instead, after the security headers and before
    # the static files (`Azu::App#default_handlers(handlers)`).
    def self.start(handlers : Array(HTTP::Handler), *, defaults : Bool = false)
      Azu::App.default.start(handlers, defaults: defaults)
    end
  end
end

# `PERFORMANCE_MONITORING=true` (or `-Dperformance_monitoring`) at build time keeps meaning "monitoring is on".
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  require "./azu/dev/dev"
{% end %}

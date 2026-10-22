require "http"
require "log"
require "radix"
require "json"
require "xml"
require "colorize"
require "schema"
require "crinja"
require "./azu/router"
require "./azu/cache"
require "./azu/performance_metrics"
require "./azu/query_store"
require "./azu/request_context"
require "./azu/development_tools"
require "./azu/performance_reporter"
require "./azu/*"
require "./azu/components/**"
require "./azu/handler/**"
require "./azu/helpers/**"
require "./azu/templates/**"

# Not globbed on purpose: `azu/cql`, `azu/database` and `azu/model` are opt-in and need the cql shard.

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
  # # Outside the block, global CONFIG is used again
  # ```
  def self.with_config(config : Configuration, &)
    @@config_mutex.synchronize do
      @@fiber_configs[Fiber.current] = config
    end
    begin
      yield
    ensure
      @@config_mutex.synchronize do
        @@fiber_configs.delete(Fiber.current)
      end
    end
  end

  # Clear all fiber-local configurations
  #
  # Useful for cleanup in test suites.
  def self.clear_fiber_configs : Nil
    @@config_mutex.synchronize do
      @@fiber_configs.clear
    end
  end

  @@boot_hooks = [] of Proc(Nil)
  @@shutdown_hooks = [] of Proc(Nil)

  # Registers work to run once when the server starts (before it binds a port).
  # Integrations such as `azu/database` use it to connect and verify resources.
  def self.on_boot(&block : ->) : Nil
    @@boot_hooks << block
  end

  # Registers work to run when the server receives SIGINT.
  def self.on_shutdown(&block : ->) : Nil
    @@shutdown_hooks << block
  end

  def self.run_boot_hooks : Nil
    @@boot_hooks.each(&.call)
  end

  def self.run_shutdown_hooks : Nil
    @@shutdown_hooks.each do |hook|
      hook.call
    rescue ex
      CONFIG.log.error(exception: ex) { "Shutdown hook failed" }
    end
  end

  # Rails-like cache API
  def self.cache
    current_config.cache
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

    def self.start(handlers : Array(HTTP::Handler))
      Azu.run_boot_hooks

      server = if handlers.empty?
                 HTTP::Server.new { |context| config.router.process(context) }
               else
                 HTTP::Server.new(handlers) { |context| config.router.process(context) }
               end

      if config.tls?
        server.bind_tls config.host, config.port, config.tls, config.port_reuse?
      else
        server.bind_tcp config.host, config.port, config.port_reuse?
      end

      Signal::INT.trap do
        Signal::INT.reset
        log.info { "Shutting down server" }
        Azu.run_shutdown_hooks
        server.close
      end

      loop do
        begin
          log.info { server_info }
          server.listen
          break
        rescue e
          if e == Errno
            log.info(exception: e) { "Restarting server..." }
          else
            log.error(exception: e) { "Server failed to start!" }
            break
          end
        end
      end
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

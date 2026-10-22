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

  # Rails-like cache API
  def self.cache
    current_config.cache
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

    def self.start(handlers : Array(HTTP::Handler))
      config.handlers = handlers.map(&.as(HTTP::Handler))
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

      {% for signal in [:INT, :TERM] %}
        Signal::{{ signal.id }}.trap do
          Signal::{{ signal.id }}.reset
          log.info { "Shutting down server" }
          server.close
        end
      {% end %}

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

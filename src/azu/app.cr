require "http/server"

module Azu
  # An application as a value: its own configuration and router, so two can live in one process and
  # each request sees the configuration of the app that serves it.
  #
  # ```
  # app = Azu::App.new
  # app.config.env = Azu::Environment::Production
  # app.router.get "/hello", HelloEndpoint.new
  # server = app.server([Azu::Handler::RequestId.new] of HTTP::Handler)
  # ```
  #
  # `Azu::CONFIG`, `configure` and `include Azu` keep working: they drive `App.default`, the app
  # built around that global configuration.
  class App
    getter config : Configuration

    @@default : App?

    # The app around the global `Azu::CONFIG`, which `include Azu` and the endpoint macros use.
    def self.default : App
      @@default ||= new(CONFIG)
    end

    def initialize(@config : Configuration = Configuration.new)
    end

    def router : Router
      @config.router
    end

    # Makes this app the current one while the rest of the handler chain runs, so
    # `Azu.current_config` answers with this app's configuration for that request.
    class Scope
      include HTTP::Handler

      def initialize(@app : App)
      end

      def call(context : HTTP::Server::Context)
        Azu.with_config(@app.config) { call_next(context) }
      end
    end

    # The handler chain this app serves: its scope first, then `handlers`.
    def chain(handlers : Array(HTTP::Handler) = [] of HTTP::Handler) : Array(HTTP::Handler)
      [Scope.new(self)] of HTTP::Handler + handlers
    end

    # An `HTTP::Server` for this app. It is not bound or started: call `bind_tcp`/`listen` on it, or
    # `bind_unused_port` in specs.
    def server(handlers : Array(HTTP::Handler) = [] of HTTP::Handler) : HTTP::Server
      HTTP::Server.new(chain(handlers)) { |context| router.process(context) }
    end
  end
end

require "http/server"

module Azu
  # An application as a value: its own configuration and router, so two can live in one process.
  # Code that runs while a request is being handled, including WebSocket callbacks and fibers
  # started with `Azu.spawn_scoped`, sees the configuration of the app that serves it through
  # `Azu.current_config`.
  #
  # Not yet per app, and shared by every app in the process: the endpoint macros (they register on
  # `App.default`), `Channel.ws`, the PubSub backend, Spark connections, `QueryStore`, the helper and
  # i18n registries, and handler constructors whose defaults read the global `CONFIG` (`Logger`,
  # `SimpleLogger`, `Throttle`, `Static`: pass `log:` explicitly). Building the server applies the
  # app's `i18n` settings to the process-wide `Helpers::I18n` (the last app to serve wins). Later
  # slices of the 0.6 plan move these.
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

    @server : HTTP::Server?
    @lock = Mutex.new
    @in_flight = 0
    @draining = false
    @idle_waiters = [] of ::Channel(Nil)

    def initialize(@config : Configuration = Configuration.new)
    end

    def router : Router
      @config.router
    end

    # Declares this app's routes: verbs, `ws`, `scope` and `mount`. See `Router::Builder`.
    def routes(&) : Nil
      with Router::Builder.new(router) yield
    end

    # Makes this app the current one while the rest of the handler chain runs, so
    # `Azu.current_config` answers with this app's configuration for that request.
    class Scope
      include HTTP::Handler

      def initialize(@app : App)
      end

      def call(context : HTTP::Server::Context)
        return if @app.track { Azu.with_config(@app.config) { call_next(context) } }

        context.response.status_code = 503
        context.response.headers["Connection"] = "close"
        context.response.headers["Retry-After"] = "1"
      end
    end

    # Counts a request as in flight while the block runs, so `stop` can wait for it. False, without
    # running the block, once the app is shutting down.
    def track(&) : Bool
      return false unless enter

      begin
        yield
      ensure
        leave
      end
      true
    end

    def draining? : Bool
      @lock.synchronize { @draining }
    end

    # From now on requests are refused with a 503, so only the ones already running need waiting for.
    def begin_shutdown : Nil
      @lock.synchronize { @draining = true }
    end

    # Waits until every request in flight has finished, or `timeout` has passed. True when none is left.
    def drain(timeout : Time::Span = @config.shutdown_timeout) : Bool
      idle = ::Channel(Nil).new
      @lock.synchronize do
        return true if @in_flight.zero?
        @idle_waiters << idle
      end

      select
      when idle.receive?
        true
      when timeout(timeout)
        @lock.synchronize { @idle_waiters.delete(idle) }
        false
      end
    end

    # Stops accepting connections and waits, up to `timeout`, for the requests in flight. True when
    # all of them finished. This is what SIGTERM and SIGINT do in `Azu.start`. It closes the server
    # most recently built by `server`.
    def stop(timeout : Time::Span = @config.shutdown_timeout) : Bool
      begin_shutdown
      @server.try(&.close)
      drain(timeout)
    end

    private def enter : Bool
      @lock.synchronize do
        return false if @draining
        @in_flight += 1
        true
      end
    end

    private def leave : Nil
      @lock.synchronize do
        @in_flight -= 1
        return unless @in_flight.zero?
        @idle_waiters.each(&.close)
        @idle_waiters.clear
      end
    end

    # The handler chain this app serves: its scope first, then `handlers`.
    #
    # A handler holds the next handler of the chain it is in, so an instance can be in one chain
    # only: reusing one for a second app would point the first app at the second one's router.
    def chain(handlers : Array(HTTP::Handler) = [] of HTTP::Handler) : Array(HTTP::Handler)
      handlers.each do |handler|
        raise ArgumentError.new("#{handler.class} is already part of a chain; use one handler instance per server") if handler.next
      end
      [Scope.new(self)] of HTTP::Handler + handlers
    end

    # The handlers `Azu.start` uses when none are given: a request id, request logging, error pages,
    # security headers and static files from `public/` (falling through to the router). Fresh
    # instances on every call, since a handler can be in one chain only.
    def default_handlers : Array(HTTP::Handler)
      [
        Handler::RequestId.new,
        Handler::Logger.new(@config.log),
        Handler::Rescuer.new,
        Handler::SecurityHeaders.new(hsts: @config.tls?),
        Handler::Static.new(fallthrough: true, cache_max_age: @config.assets.cache_max_age),
      ] of HTTP::Handler
    end

    # An `HTTP::Server` for this app. It is not bound or started: call `bind_tcp`/`listen` on it, or
    # `bind_unused_port` in specs.
    def server(handlers : Array(HTTP::Handler) = [] of HTTP::Handler) : HTTP::Server
      @config.i18n.apply
      HTTP::Server.new(chain(handlers)) { |context| router.process(context) }.tap { |server| @server = server }
    end
  end
end

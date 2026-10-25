require "http/server"

module Azu
  # An application as a value: its own configuration and router, so two can live in one process.
  # Code that runs while a request is being handled, including WebSocket callbacks and fibers
  # started with `Azu.spawn_scoped`, sees the configuration of the app that serves it through
  # `Azu.current_config`.
  #
  # Endpoint macros declare their routes on the endpoint type, and `App.default` registers them on first
  # use; another app takes a type with `Router::Builder#endpoint`.
  #
  # Not yet per app, and shared by every app in the process: `Channel.ws` (it registers on `App.default`), the PubSub
  # backend, Spark connections, `QueryStore`, the helper and i18n registries, and handler constructors whose defaults read the global `CONFIG` (`Logger`,
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
    # Requests and sockets being served. Counted without the lock, so a request costs two atomic
    # operations; the lock covers the idle waiters and the socket set.
    @in_flight = Atomic(Int32).new(0)
    @draining = Atomic(Int32).new(0)
    @idle_waiters = [] of ::Channel(Nil)
    # How many of `@idle_waiters` there are, so the last request out only takes the lock when a drain is waiting.
    @waiting = Atomic(Int32).new(0)
    @sockets = Set(Channel).new
    @shutdown_signal = ::Channel(Nil).new

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
        return if @app.track { Azu.with_scope(@app, @app.config) { call_next(context) } }

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
      @draining.get == 1
    end

    # Closed when shutdown begins. A streaming response waits on it (`Azu.shutdown_signal`).
    getter shutdown_signal : ::Channel(Nil)

    # Counts an open WebSocket as in flight while the block runs, and closes it with 1001 (going
    # away) when shutdown begins. False, without running the block, once the app is shutting down.
    def track_socket(channel : Channel, &) : Bool
      return false unless @lock.synchronize { enter_socket(channel) }

      begin
        yield
      ensure
        @lock.synchronize { @sockets.delete(channel) }
        leave
      end
      true
    end

    # From now on requests are refused with a 503, so only the ones already running need waiting for.
    # Open WebSockets are sent a close frame with code 1001 right away (one fiber each, so a stuck
    # peer cannot hold this up), and the shutdown signal is raised for streaming responses. The
    # sockets count as in flight until their peers answer the close frame, so `drain` waits for them
    # within the same `shutdown_timeout`.
    def begin_shutdown : Nil
      sockets = @lock.synchronize do
        return if draining?
        @draining.set(1)
        @sockets.to_a
      end
      @shutdown_signal.close
      sockets.each { |socket| spawn(name: "azu-ws-goaway") { socket.close(HTTP::WebSocket::CloseCode::GoingAway, "server shutting down") } }
    end

    # Waits until every request in flight has finished, or `timeout` has passed. True when none is left.
    def drain(timeout : Time::Span = @config.shutdown_timeout) : Bool
      idle = ::Channel(Nil).new
      @lock.synchronize do
        # Announced before the count is read, see `leave`
        @waiting.add(1)
        if @in_flight.get.zero?
          @waiting.sub(1)
          return true
        end
        @idle_waiters << idle
      end

      select
      when idle.receive?
        true
      when timeout(timeout)
        @lock.synchronize { @waiting.sub(1) if @idle_waiters.delete(idle) }
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

    private def enter_socket(channel : Channel) : Bool
      return false if draining?
      @in_flight.add(1)
      @sockets << channel
      true
    end

    # Counts first and looks at `@draining` after: `begin_shutdown` sets the flag before `drain` reads
    # the count, so a request is either refused here or seen by the drain.
    private def enter : Bool
      @in_flight.add(1)
      return true unless draining?

      leave
      false
    end

    # `Atomic#sub` answers with the value from before: 1 means this was the last one. Only then, and
    # only when a drain announced itself in `@waiting` before it read the count (so one of the two
    # sees the other), the lock is taken to wake it. The count is read again under the lock because a
    # request can have entered since.
    private def leave : Nil
      return unless @in_flight.sub(1) == 1
      return if @waiting.get.zero?

      @lock.synchronize do
        return unless @in_flight.get.zero?
        @idle_waiters.each(&.close)
        @idle_waiters.clear
        @waiting.set(0)
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
      HTTP::Server.new(dispatcher(handlers)).tap { |server| @server = server }
    end

    # The first handler of the chain `server` serves, ending in the router: calling it with a context
    # handles a request without a socket (this is what `Azu::Testing::Client` does).
    def dispatcher(handlers : Array(HTTP::Handler) = [] of HTTP::Handler) : HTTP::Handler
      @config.i18n.apply
      router # takes the declared endpoints now, so a duplicate route fails at boot, not on a request
      HTTP::Server.build_middleware(chain(handlers), ->(context : HTTP::Server::Context) { router.process(context) })
    end
  end
end

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
  # `Azu::CONFIG`, `configure` and `include Azu` are the supported single-app facade: they drive `App.default`,
  # the app built around the global configuration, and the facade's `start` is `App.default.start`. They share that
  # one global `CONFIG`, so a process has one facade app; build an `Azu::App` and `start` it to run another.
  #
  # ```
  # app = Azu::App.new
  # app.config.port = 3000
  # app.router.get "/hello", HelloEndpoint.new
  # app.start # binds, serves until SIGINT/SIGTERM or `app.stop`, then drains and shuts the framework down
  # ```
  class App
    # `start` was called on an app that is already running.
    class AlreadyRunning < Exception
      def initialize
        super("the app is already running")
      end
    end

    # `start` was called on an app that has stopped, or has begun shutting down: an app starts once.
    class AlreadyStopped < Exception
      def initialize
        super("the app has stopped and cannot be started again: build a new Azu::App")
      end
    end

    getter config : Configuration

    @@default : App?
    @@default_lock = Mutex.new

    # The app around the global `Azu::CONFIG`, which `include Azu` and the endpoint macros use. Built once, even when
    # fibers on several threads ask for it at the same time.
    def self.default : App
      @@default_lock.synchronize { @@default ||= new(CONFIG) }
    end

    # Replaces the default app, which cannot start again once it has stopped. For specs that start it.
    def self.default=(app : App) : App
      @@default_lock.synchronize { @@default = app }
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
    @started_once = false

    @@running = [] of App
    @@running_lock = Mutex.new
    @@signals_trapped = false

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
    # all of them finished. This is what SIGTERM and SIGINT do for a started app. It closes the server
    # most recently built by `server`; `start` returns once it is closed and drained.
    def stop(timeout : Time::Span = @config.shutdown_timeout) : Bool
      begin_shutdown
      close_server
      drain(timeout)
    end

    # Starts what needs a running app: the async log pipeline, the upload temp directory and cleanup, the
    # `Instrumentation.on_prepare` hooks (see `Configuration#prepare`). `start` calls it.
    def prepare : Nil
      AsyncLogging.initialize
      @config.prepare
    end

    # True from the moment `start` is called until it returns.
    def running? : Bool
      @@running_lock.synchronize { @@running.includes?(self) }
    end

    # Where the server listens, once `start` has bound it; nil before, and after the server has closed. With
    # `config.port = 0` it is the port the system chose.
    def address : Socket::IPAddress?
      http = @server
      return if http.nil? || http.closed?
      http.addresses.first?.as?(Socket::IPAddress)
    end

    # Serves the app until `stop`, SIGINT or SIGTERM, then returns. The lifecycle behind `include Azu`'s `start`:
    #
    # 1. the server for *handlers* (`default_handlers` when none are given: an array is used exactly as given),
    #    bound to `config.host` and `config.port`, over TLS when `config.tls?`. A bind error is raised to the caller
    #    with nothing left behind: the handlers are unchained (the same array can be used again), nothing was prepared;
    # 2. `prepare`, then the log lines about the environment and the address (`Configuration#announce_default_environment`
    #    and `#warn_about_bind_host`);
    # 3. with *signals*, SIGINT and SIGTERM stop every app started this way (`begin_shutdown`, then the server
    #    closes); a second signal finds the default handler again. The traps are process-wide and replace any trap
    #    the program installed (there is no chaining): pass `signals: false` to leave them alone and stop the app
    #    yourself with `stop`;
    # 4. `listen`, which blocks; afterwards the requests in flight get `config.shutdown_timeout` to finish;
    # 5. with *teardown*, `Azu.shutdown` (Spark, presence, PubSub, `Azu.on_shutdown` hooks such as the database
    #    pools, Redis) once the last started app has stopped. Those parts are shared by every app in the process, so
    #    `teardown: false` is for an app embedded in a program that stops them itself, and for specs.
    #
    # An app starts **once**: `start` on a running app raises `AlreadyRunning`, and on an app that has stopped (or
    # begun shutting down) raises `AlreadyStopped`; build a new `Azu::App` to serve again. A `start` that failed to bind
    # does not count: it can be called again.
    def start(handlers : Array(HTTP::Handler) = default_handlers, *, signals : Bool = true, teardown : Bool = true) : Nil
      register
      begin
        serve(handlers, signals)
      ensure
        unregister
      end
      Azu.shutdown if teardown && @@running_lock.synchronize { @@running.empty? }
    end

    private def serve(handlers : Array(HTTP::Handler), signals : Bool) : Nil
      started = Time.instant
      http = server(handlers)
      bring_up(http, handlers)
      @started_once = true
      @config.announce_default_environment
      @config.warn_about_bind_host
      @config.handlers = handlers.map(&.as(HTTP::Handler))
      App.trap_signals if signals

      begin
        @config.log.info { startup_banner(started) }
        http.listen
      rescue e
        @config.log.error(exception: e) { "Server failed to start!" } unless draining?
      end

      @config.log.warn { "Shutdown timeout: requests still in flight were dropped" } unless drain
    end

    # Binds, then prepares; if either raises, undoes what was done so the call can be repeated with the same handlers.
    private def bring_up(http : HTTP::Server, handlers : Array(HTTP::Handler)) : Nil
      bind(http)
      prepare
    rescue e
      http.close unless http.closed?
      @server = nil
      handlers.each(&.next=(nil))
      raise e
    end

    private def bind(http : HTTP::Server) : Nil
      if @config.tls?
        Azu.bind_tls http, @config.host, @config.port, @config.tls, @config.port_reuse?, @config.websocket.tcp_nodelay?
      else
        http.bind_tcp @config.host, @config.port, @config.port_reuse?
      end
    end

    private def register : Nil
      @@running_lock.synchronize do
        raise AlreadyRunning.new if @@running.includes?(self)
        raise AlreadyStopped.new if @started_once || draining?
        @@running << self
      end
    end

    private def unregister : Nil
      last = @@running_lock.synchronize do
        @@running.delete(self)
        @@running.empty?
      end
      App.release_signals if last
    end

    # True while the process-wide SIGINT/SIGTERM trap installed by `start` is in place. It is false again as soon as a
    # signal has fired (the default handler is back), so an app started while another drains gets its own trap.
    def self.signals_trapped? : Bool
      @@running_lock.synchronize { @@signals_trapped }
    end

    # SIGINT and SIGTERM stop every running app. Installed once; a signal puts the default handlers back first.
    protected def self.trap_signals : Nil
      @@running_lock.synchronize do
        return if @@signals_trapped
        # The flag says the traps are in place (a spec, or a thread, may signal the process once it is up), so it is
        # set after they are installed. A signal that arrives meanwhile waits on this lock in `signal_received`.
        {% for signal in [:INT, :TERM] %}
          Signal::{{ signal.id }}.trap do
            App.signal_received
            App.interrupt_running
          end
        {% end %}
        @@signals_trapped = true
      end
    end

    # The trap fired: the process owns no trap any more.
    protected def self.signal_received : Nil
      @@running_lock.synchronize { @@signals_trapped = false }
      Signal::INT.reset
      Signal::TERM.reset
    end

    protected def self.interrupt_running : Nil
      apps = @@running_lock.synchronize { @@running.dup }
      apps.each do |app|
        app.config.log.info { "Shutting down server" }
        app.begin_shutdown
        app.close_server
      end
    end

    # Puts the default handlers back when the last app stops, but only while the trap is still ours.
    protected def self.release_signals : Nil
      owned = @@running_lock.synchronize { @@signals_trapped.tap { @@signals_trapped = false } }
      return unless owned
      Signal::INT.reset
      Signal::TERM.reset
    end

    protected def close_server : Nil
      @server.try { |http| http.close unless http.closed? }
    end

    private def startup_banner(started : Time::Instant) : String
      String.build do |io|
        io << "Server started at #{Time.local.to_s("%a %m/%d/%Y %I:%M:%S")}.".colorize(:white).underline
        io << "\n   ⤑  Environment: ".colorize(:white)
        io << @config.env.colorize(:light_blue)
        io << "\n   ⤑  Host: ".colorize(:white)
        io << @config.host.colorize(:light_blue)
        io << "\n   ⤑  Port: ".colorize(:white)
        io << (address.try(&.port) || @config.port).colorize(:light_blue)
        io << "\n   ⤑  Startup Time: ".colorize(:white)
        io << (Time.instant - started).total_milliseconds
        io << " millis".colorize(:white)
      end
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

require "../spec_helper"
require "http/client"
require "log/spec"

module AppStartSpec
  struct Hello
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response << "hello from #{Azu.current_config.port}"
      context
    end
  end

  struct Ping
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response << "pong"
      context
    end
  end

  ENTERED = ::Channel(Nil).new(4)
  GATE    = ::Channel(Nil).new

  struct Slow
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      ENTERED.send(nil)
      GATE.receive
      context.response << "finished"
      context
    end
  end

  # An app on an ephemeral loopback port.
  def self.app(path : String, routable : Azu::Routable) : Azu::App
    app = Azu::App.new
    app.config.host = "127.0.0.1"
    app.config.port = 0
    app.router.get path, routable
    app
  end

  # Runs `app.start` in a fiber; the channel receives when it returns.
  def self.boot(app : Azu::App, handlers : Array(HTTP::Handler) = app.default_handlers, **options) : ::Channel(Nil)
    finished = ::Channel(Nil).new
    spawn(name: "app-start-spec") do
      app.start(handlers, **options)
    ensure
      finished.send(nil)
    end
    wait_until { app.address }.should be_true
    finished
  end

  # Waits until the process-wide signal trap of `start` is in place.
  def self.trapped : Bool
    wait_until { Azu::App.signals_trapped? }
  end

  def self.client(app : Azu::App) : HTTP::Client
    address = bound(app)
    HTTP::Client.new(address.address, address.port)
  end

  def self.bound(app : Azu::App) : Socket::IPAddress
    app.address || raise "#{app} is not listening"
  end
end

describe "Azu::App#start" do
  # `Azu.shutdown` (teardown) stops the process-wide PubSub, presence and Redis; put them back for the other specs.
  around_each do |example|
    pub_sub = Azu::PubSub.backend
    presence = Azu::Presence.default
    begin
      example.run
    ensure
      Azu::PubSub.backend = pub_sub
      Azu::Presence.default = presence
    end
  end

  it "serves an app built as a value, without the global CONFIG" do
    app = AppStartSpec.app("/hello", AppStartSpec::Hello.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)

    response = AppStartSpec.client(app).get("/hello")
    response.status_code.should eq 200
    response.body.should eq "hello from 0"
    response.headers["X-Request-ID"]?.should_not be_nil # the default handler stack

    app.stop(2.seconds).should be_true
    finished.receive
  end

  it "uses the handlers it is given exactly as given" do
    app = AppStartSpec.app("/hello", AppStartSpec::Hello.new)
    finished = AppStartSpec.boot(app, [] of HTTP::Handler, teardown: false, signals: false)

    AppStartSpec.client(app).get("/hello").headers["X-Request-ID"]?.should be_nil
    app.config.handlers.should be_empty
    app.stop(2.seconds)
    finished.receive
  end

  it "runs two apps in one process, each with its own routes" do
    first = AppStartSpec.app("/first", AppStartSpec::Hello.new)
    second = AppStartSpec.app("/second", AppStartSpec::Ping.new)
    done_first = AppStartSpec.boot(first, teardown: false, signals: false)
    done_second = AppStartSpec.boot(second, teardown: false, signals: false)

    AppStartSpec.bound(first).port.should_not eq AppStartSpec.bound(second).port
    AppStartSpec.client(first).get("/first").body.should eq "hello from 0"
    AppStartSpec.client(first).get("/second").status_code.should eq 404
    AppStartSpec.client(second).get("/second").body.should eq "pong"
    AppStartSpec.client(second).get("/first").status_code.should eq 404

    first.stop(2.seconds)
    done_first.receive
    AppStartSpec.client(second).get("/second").body.should eq "pong" # the other one keeps serving
    second.stop(2.seconds)
    done_second.receive
  end

  it "returns once the app is stopped, and stops answering" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)
    client = AppStartSpec.client(app)

    app.stop(2.seconds).should be_true
    finished.receive
    app.running?.should be_false
    expect_raises(IO::Error) { HTTP::Client.new(client.host, client.port).get("/ping") }
  end

  it "freezes the routers before it listens, a mounted app's too" do
    child = Azu::App.new
    app = AppStartSpec.app("/hello", AppStartSpec::Hello.new)
    app.routes { mount child, at: "/child" }
    finished = AppStartSpec.boot(app, teardown: false, signals: false)
    begin
      AppStartSpec.client(app).get("/hello").status_code.should eq 200 # it listens, so it froze them

      expect_raises(Azu::Router::Frozen, "declare them before App#start") { app.router.get "/late", AppStartSpec::Ping.new }
      expect_raises(Azu::Router::Frozen) { child.router.get "/late", AppStartSpec::Ping.new }
    ensure
      app.stop(2.seconds)
      finished.receive
    end
  end

  it "refuses to start an app that is running" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)

    expect_raises(Azu::App::AlreadyRunning) { app.start(teardown: false, signals: false) }
    app.stop(2.seconds)
    finished.receive
  end

  it "runs the shutdown hooks and stops the framework once the last app stops, like the facade did" do
    hooks = 0
    Azu.on_shutdown { hooks += 1 }
    first = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    second = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    done_first = AppStartSpec.boot(first, signals: false)
    done_second = AppStartSpec.boot(second, signals: false)

    first.stop(2.seconds)
    done_first.receive
    hooks.should eq 0 # the second app still needs PubSub, Redis, the database pools

    second.stop(2.seconds)
    done_second.receive
    hooks.should eq 1
  end

  it "leaves the shutdown hooks alone with teardown: false" do
    hooks = 0
    Azu.on_shutdown { hooks += 1 }
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)
    app.stop(2.seconds)
    finished.receive
    hooks.should eq 0
  end

  it "stops on SIGTERM when it traps signals, and lets go of the signal afterwards" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false)
    AppStartSpec.trapped.should be_true

    Process.signal(Signal::TERM, Process.pid)
    select
    when finished.receive
    when timeout(5.seconds)
      fail "the app did not stop on SIGTERM"
    end
    app.draining?.should be_true
    Azu::App.signals_trapped?.should be_false
  end

  it "stops every running app on SIGTERM" do
    first = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    second = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    done_first = AppStartSpec.boot(first, teardown: false)
    done_second = AppStartSpec.boot(second, teardown: false)
    AppStartSpec.trapped.should be_true

    Process.signal(Signal::TERM, Process.pid)
    [done_first, done_second].each do |finished|
      select
      when finished.receive
      when timeout(5.seconds)
        fail "an app did not stop on SIGTERM"
      end
    end
  end

  it "starts once: an app that has stopped raises AlreadyStopped" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)
    app.stop(2.seconds)
    finished.receive

    expect_raises(Azu::App::AlreadyStopped, /build a new Azu::App/) { app.start(teardown: false, signals: false) }
    app.running?.should be_false
  end

  it "refuses to start an app that began shutting down before it ran" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    app.begin_shutdown
    expect_raises(Azu::App::AlreadyStopped) { app.start(teardown: false, signals: false) }
  end

  it "leaves nothing behind when the port is taken, and can be started again with the same handlers" do
    prepared = 0
    Azu::Instrumentation.on_prepare { |_config| prepared += 1 }
    taken = TCPServer.new("127.0.0.1", 0)
    begin
      app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
      app.config.port_reuse = false
      app.config.port = taken.local_address.port
      handlers = [Azu::Handler::RequestId.new] of HTTP::Handler

      expect_raises(Socket::BindError) { app.start(handlers, teardown: false, signals: false) }

      app.running?.should be_false
      app.address.should be_nil
      handlers.first.next.should be_nil
      prepared.should eq 0

      app.config.port = 0
      finished = AppStartSpec.boot(app, handlers, teardown: false, signals: false)
      AppStartSpec.client(app).get("/ping").body.should eq "pong"
      prepared.should eq 1
      app.stop(2.seconds)
      finished.receive
    ensure
      taken.close
    end
  end

  it "has no address once the server has closed" do
    app = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    finished = AppStartSpec.boot(app, teardown: false, signals: false)
    app.stop(2.seconds)
    finished.receive
    app.address.should be_nil
  end

  it "gives an app started while another drains its own signal trap" do
    first = AppStartSpec.app("/slow", AppStartSpec::Slow.new)
    done_first = AppStartSpec.boot(first, teardown: false)
    AppStartSpec.trapped.should be_true
    spawn { AppStartSpec.client(first).get("/slow") rescue nil }
    AppStartSpec::ENTERED.receive

    Process.signal(Signal::TERM, Process.pid)
    wait_until { first.draining? }.should be_true
    Azu::App.signals_trapped?.should be_false # the signal put the default handlers back

    second = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    done_second = AppStartSpec.boot(second, teardown: false)
    AppStartSpec.trapped.should be_true

    AppStartSpec::GATE.send(nil)
    done_first.receive
    Azu::App.signals_trapped?.should be_true # the second app still owns its trap
    second.stop(2.seconds)
    done_second.receive
    Azu::App.signals_trapped?.should be_false
  end

  it "logs one INFO line when the environment is the default" do
    saved = ENV["CRYSTAL_ENV"]?
    saved_host = ENV["HOST"]?
    ENV.delete("CRYSTAL_ENV")
    ENV.delete("HOST")
    begin
      app = Azu::App.new
      app.config.port = 0
      app.config.container = false
      app.config.log = ::Log.for("spec.app_start")
      logs = ::Log.capture("spec.app_start") do
        finished = AppStartSpec.boot(app, teardown: false, signals: false)
        app.stop(2.seconds)
        finished.receive
      end
      logs.check(:info, /CRYSTAL_ENV not set, running in development, listening on 127\.0\.0\.1/)
    ensure
      saved ? (ENV["CRYSTAL_ENV"] = saved) : ENV.delete("CRYSTAL_ENV")
      saved_host ? (ENV["HOST"] = saved_host) : ENV.delete("HOST")
    end
  end
end

# The facade: `include Azu` drives App.default through the same path.
module AppStartSpec::Facade
  include Azu
end

describe "the include Azu facade" do
  # App.default cannot start again once it has stopped, and Azu.shutdown stops the process-wide parts: give the example
  # its own default app and put everything back. The app has its own configuration too, because starting freezes its
  # router and the global one takes routes in other specs (`Endpoint.get` called in an example).
  around_each do |example|
    original = Azu::App.default
    pub_sub = Azu::PubSub.backend
    presence = Azu::Presence.default
    Azu::App.default = Azu::App.new(Azu::Configuration.new)
    begin
      example.run
    ensure
      Azu::App.default = original
      Azu::PubSub.backend = pub_sub
      Azu::Presence.default = presence
    end
  end

  it "starts App.default through App#start" do
    app = Azu::App.default
    config = app.config
    config.host = "127.0.0.1"
    config.port = 0
    finished = ::Channel(Nil).new
    spawn(name: "facade-start-spec") do
      AppStartSpec::Facade.start([] of HTTP::Handler)
    ensure
      finished.send(nil)
    end
    wait_until { app.address }.should be_true
    AppStartSpec.client(app).get("/nothing-routed").status_code.should eq 404 # answered by App.default's router
    app.running?.should be_true
    config.handlers.should be_empty
    app.stop(2.seconds)
    finished.receive
  end

  it "does not log a deprecation warning" do
    Log.capture("Azu") do |logs|
      AppStartSpec::Facade.configure { }
      logs.empty
    end
  end
end

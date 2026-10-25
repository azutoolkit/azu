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

  def self.client(app : Azu::App) : HTTP::Client
    address = bound(app)
    HTTP::Client.new(address.address, address.port)
  end

  def self.bound(app : Azu::App) : Socket::IPAddress
    app.address || raise "#{app} is not listening"
  end
end

describe "Azu::App#start" do
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

    Process.signal(Signal::TERM, Process.pid)
    select
    when finished.receive
    when timeout(5.seconds)
      fail "the app did not stop on SIGTERM"
    end
    app.draining?.should be_true
  end

  it "stops every running app on SIGTERM" do
    first = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    second = AppStartSpec.app("/ping", AppStartSpec::Ping.new)
    done_first = AppStartSpec.boot(first, teardown: false)
    done_second = AppStartSpec.boot(second, teardown: false)

    Process.signal(Signal::TERM, Process.pid)
    [done_first, done_second].each do |finished|
      select
      when finished.receive
      when timeout(5.seconds)
        fail "an app did not stop on SIGTERM"
      end
    end
  end

  it "logs one INFO line when the environment is the default" do
    saved = ENV["CRYSTAL_ENV"]?
    saved_host = ENV["HOST"]?
    ENV.delete("CRYSTAL_ENV")
    ENV.delete("HOST")
    begin
      app = Azu::App.new
      app.config.port = 0
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
  it "starts App.default through App#start" do
    config = Azu::CONFIG
    saved = {config.host, config.port}
    config.host = "127.0.0.1"
    config.port = 0
    app = Azu::App.default
    app.router.get "/facade-ping", AppStartSpec::Ping.new
    finished = ::Channel(Nil).new
    spawn(name: "facade-start-spec") do
      AppStartSpec::Facade.start([] of HTTP::Handler)
    ensure
      finished.send(nil)
    end
    begin
      wait_until { app.address }.should be_true
      AppStartSpec.client(app).get("/facade-ping").body.should eq "pong"
      config.handlers.should be_empty
      app.stop(2.seconds)
      finished.receive
    ensure
      config.host, config.port = saved
    end
  end

  it "does not log a deprecation warning" do
    Log.capture("Azu") do |logs|
      AppStartSpec::Facade.configure { }
      logs.empty
    end
  end
end

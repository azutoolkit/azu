require "../../spec_helper"
require "file_utils"
require "../../../src/azu/testing/testing"

module TestingHardeningSpec
  struct Show
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response << "#{context.request.method} #{context.request.path}?#{context.request.query_params} #{context.request.body.try(&.gets_to_end)}"
    end
  end

  struct Cookies
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.cookies << HTTP::Cookie.new("scoped", "1", path: "/admin")
      context.response << "set"
    end
  end

  struct Away
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.status = :found
      context.response.headers["Location"] = "http://elsewhere.example/landing"
    end
  end

  struct Ttl
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.cookies << HTTP::Cookie.new("ttl", "1", path: "/", max_age: 60.seconds)
      context.response << "set"
    end
  end

  struct Req
    include Azu::Request

    getter path : String = ""

    def initialize(@path = "")
    end
  end

  struct Res
    include Azu::Response

    def initialize(@text : String = "")
    end

    def render
      @text
    end
  end

  struct FilesEndpoint
    include Azu::Endpoint(Req, Res)

    def call : Res
      Res.new params["path"]
    end
  end

  struct WriteOnly
    include Azu::Endpoint(Req, Res)

    def call : Res
      Res.new
    end
  end

  struct Twice
    include Azu::Endpoint(Req, Res)

    def call : Res
      Res.new
    end
  end

  class Echo < Azu::Channel
    def on_connect
    end

    def on_message(message : String)
      send message
    end

    def on_binary(binary : Bytes)
    end

    def on_ping(message : String)
    end

    def on_pong(message : String)
    end

    def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
    end
  end

  def self.app : Azu::App
    app = Azu::App.new
    app.routes do
      get "/show", Show
      post "/show", Show
      get "/admin/cookie", Cookies
      get "/administrator", Show
      get "/admin/x", Show
      get "/away", Away
      get "/ttl", Ttl
      get "/files/*path", FilesEndpoint
      post "/write", WriteOnly
      get "/a", Twice
      get "/b", Twice
      ws "/echo", Echo
    end
    app
  end
end

describe Azu::Testing::Client do
  it "encodes arrays as repeated keys, drops nil and stringifies values in form and params" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    client.get("/show", params: {ids: [1, 2], skip: nil, n: 3}).body.should contain "ids=1&ids=2&n=3 "
    client.post("/show", form: {tags: ["a", "b"], gone: nil}).body.should end_with " tags=a&tags=b"
  end

  it "sends json: false and json: nil as bodies" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    client.post("/show", json: false).body.should end_with " false"
    client.post("/show", json: nil).body.should end_with " null"
  end

  it "encodes a wildcard path parameter segment by segment" do
    app = TestingHardeningSpec.app
    client = Azu::Testing::Client.new(app, [] of HTTP::Handler)
    client.get(TestingHardeningSpec::FilesEndpoint, path: "a b/c").body.should eq "a%20b/c"
  end

  it "looks the route up by verb and names the verbs an endpoint is routed for" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    expect_raises(ArgumentError, /not routed for GET.*POST \/write/) { client.get(TestingHardeningSpec::WriteOnly, path: "x") }
    client.post(TestingHardeningSpec::WriteOnly, path: "x").status_code.should eq 200
  end

  it "refuses an endpoint routed at several paths for the verb" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    expect_raises(ArgumentError, /several paths.*\/a.*\/b/) { client.get(TestingHardeningSpec::Twice, path: "x") }
  end

  it "sends a cookie only to its path or below it" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    client.get "/admin/cookie"
    client.cookies.header_for("/admin").should eq "scoped=1"
    client.cookies.header_for("/admin/x").should eq "scoped=1"
    client.cookies.header_for("/administrator").should be_nil
  end

  it "does not follow a redirect to another host" do
    client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler)
    client.follow_redirects = true
    response = client.get "/away"
    response.status_code.should eq 302
    response.location.should eq "http://elsewhere.example/landing"
  end

  it "reports a closed WebSocket as closed, not as a timeout" do
    socket = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler).connect "/echo"
    socket.close
    expect_raises(Azu::Testing::WebSocket::Closed) { socket.receive }
  end

  describe "clock" do
    it "ages the cookie jar by the client's clock outside a request" do
      clock = Azu::Clock::Fake.new
      client = Azu::Testing::Client.new(TestingHardeningSpec.app, [] of HTTP::Handler, clock: clock)
      client.get "/ttl"
      client.cookies["ttl"]?.should eq "1"
      client.advance(2.minutes)
      client.cookies["ttl"]?.should be_nil
      Azu::Clock.source.should be_a Azu::Clock::System
    end

    it "leaves the process clock as it was after concurrent requests of clients with different clocks" do
      app = TestingHardeningSpec.app
      done = ::Channel(Nil).new
      4.times do
        spawn do
          Azu::Testing::Client.new(app, [] of HTTP::Handler, clock: Azu::Clock::Fake.new).get("/show")
          done.send(nil)
        end
      end
      4.times { done.receive }
      Azu::Clock.source.should be_a Azu::Clock::System
    end
  end

  describe "session adapter" do
    it "is removed from the app when the client closes" do
      app = TestingHardeningSpec.app
      client = Azu::Testing::Client.new(app, [] of HTTP::Handler)
      client.login_with { |session| session["a"] = "1" }
      app.config.session_adapter.should_not be_nil
      client.close
      app.config.session_adapter.should be_nil
    end

    it "is shared by clients of one app until the last one closes" do
      app = TestingHardeningSpec.app
      first = Azu::Testing::Client.new(app, [] of HTTP::Handler).login_with { |session| session["a"] = "1" }
      second = Azu::Testing::Client.new(app, [] of HTTP::Handler).login_with { |session| session["a"] = "2" }
      first.close
      app.config.session_adapter.should_not be_nil
      second.close
      app.config.session_adapter.should be_nil
    end

    it "gives a new configuration its own store, never a cached one" do
      first = Azu::Testing::Client.new(Azu::App.new, [] of HTTP::Handler)
      first.login_with { |session| session["a"] = "1" }
      first.close
      app = Azu::App.new
      client = Azu::Testing::Client.new(app, [] of HTTP::Handler).login_with { |session| session["b"] = "2" }
      client.cookies[Azu::Testing::Sessions::COOKIE]?.should_not be_nil
      client.close
    end

    it "yields to a block form that cleans up" do
      app = TestingHardeningSpec.app
      Azu::Testing::Client.open(app, [] of HTTP::Handler) do |client|
        client.login_with { |session| session["a"] = "1" }
        app.config.session_adapter.should_not be_nil
      end
      app.config.session_adapter.should be_nil
    end
  end

  describe "typed request of the wrong type" do
    it "does not compile" do
      next pending!("crystal is not installed") unless Process.find_executable("crystal")

      dir = File.tempname("azu-testing-compile")
      Dir.mkdir_p(dir)
      program = File.join(dir, "main.cr")
      File.write(program, <<-CR)
        require "azu"
        require "azu/testing"
        struct One
          include Azu::Request
          def initialize
          end
        end
        struct Other
          include Azu::Request
          def initialize
          end
        end
        struct Out
          include Azu::Response
          def render
            ""
          end
        end
        struct Ep
          include Azu::Endpoint(One, Out)
          def call : Out
            Out.new
          end
        end
        Azu::Testing::Client.new.post(Ep, Other.new)
        CR
      search_path = [File.expand_path("../../../src", __DIR__), File.expand_path("../../../lib", __DIR__), `crystal env CRYSTAL_PATH`.strip].join(':')
      error = IO::Memory.new
      status = Process.run("crystal", ["build", "--no-codegen", "--no-color", program], env: {"CRYSTAL_PATH" => search_path}, output: Process::Redirect::Close, error: error)
      status.success?.should be_false
      error.to_s.should contain "takes a One, not a Other"
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end

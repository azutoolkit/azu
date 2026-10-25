require "../../spec_helper"
require "../../../src/azu/testing/testing"

module TestingSpec
  struct NoteRequest
    include Azu::Request

    getter id : Int64 = 0_i64
    getter title : String = ""

    validate title, presence: true, message: "must be present"

    def initialize(@id = 0_i64, @title = "")
    end
  end

  struct NoteResponse
    include Azu::Response
    include JSON::Serializable

    getter id : Int64
    getter title : String
    getter via : String

    def initialize(@id : Int64, @title : String, @via : String)
    end

    def render
      to_json
    end
  end

  struct SaveNote
    include Azu::Endpoint(NoteRequest, NoteResponse)

    def call : NoteResponse
      content_type "application/json"
      status 201 if context.request.method == "POST"
      NoteResponse.new note_request.id, note_request.title, "#{context.request.method} #{context.request.content_type.sub_type}"
    end
  end

  struct Whoami
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.content_type = "text/plain"
      session = Azu.session_adapter.try(&.session(context)) || {} of String => String
      context.response << "user=#{session["user"]?} cookie=#{context.request.cookies["theme"]?.try(&.value)} cfg=#{Azu.current_config.env}"
    end
  end

  struct Cookies
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.cookies << HTTP::Cookie.new("theme", "dark", path: "/", max_age: 60.seconds)
      context.response << "set"
    end
  end

  struct Redirect
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      context.response.status = :see_other
      context.response.headers["Location"] = "/whoami"
    end
  end

  struct Boom
    include Azu::Routable

    def call(context : HTTP::Server::Context)
      raise "kaput"
    end
  end

  class Stamp
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      context.response.headers["X-Stamp"] = "first"
      call_next(context)
    end
  end

  class Echo < Azu::Channel
    def on_connect
    end

    def on_message(message : String)
      send "echo:#{message}"
    end

    def on_binary(binary : Bytes)
    end

    def on_ping(message : String)
    end

    def on_pong(message : String)
    end

    def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
      CLOSED.send(nil)
    end
  end

  CLOSED = ::Channel(Nil).new(4)

  def self.app : Azu::App
    app = Azu::App.new
    app.config.env = Azu::Environment::Test
    app.routes do
      get "/notes/:id", SaveNote
      post "/notes/:id", SaveNote
      get "/whoami", Whoami
      get "/cookies", Cookies
      get "/redirect", Redirect
      post "/redirect", Redirect
      get "/boom", Boom
      ws "/echo", Echo
    end
    app
  end
end

describe Azu::Testing::Client do
  it "runs a request through the handler chain in order and stamps a request id" do
    client = Azu::Testing::Client.new(TestingSpec.app, [Azu::Handler::RequestId.new, TestingSpec::Stamp.new] of HTTP::Handler)
    response = client.get "/whoami"

    response.status_code.should eq 200
    response.headers["X-Stamp"].should eq "first"
    response.header("X-Request-ID").should_not be_nil
    response.body.should contain "cfg=Test"
  end

  it "answers an unknown path and a contract violation with problem+json" do
    client = Azu::Testing::Client.new(TestingSpec.app).accept(:json)

    missing = client.get "/nope"
    missing.status_code.should eq 404
    missing.content_type.should eq "application/problem+json"
    missing.problem?.should be_true
    JSON.parse(missing.body)["title"].should eq "Not Found"

    invalid = client.post "/notes/1", json: {title: ""}
    invalid.status_code.should eq 422
    invalid.problem?.should be_true
  end

  it "keeps cookies between requests, per client, and expires them with the fake clock" do
    clock = Azu::Clock::Fake.new
    app = TestingSpec.app
    client = Azu::Testing::Client.new(app, clock: clock)
    other = Azu::Testing::Client.new(app)

    client.get("/cookies").cookies["theme"].value.should eq "dark"
    client.get("/whoami").body.should contain "cookie=dark"
    other.get("/whoami").body.should contain "cookie= "

    client.advance(2.minutes)
    client.get("/whoami").body.should contain "cookie= "
  end

  it "follows redirects only when asked" do
    client = Azu::Testing::Client.new(TestingSpec.app)
    plain = client.post "/redirect"
    plain.status_code.should eq 303
    plain.location.should eq "/whoami"

    client.follow_redirects = true
    client.post("/redirect").body.should contain "cfg=Test"
  end

  it "encodes json, form and query bodies so the endpoint parses them" do
    client = Azu::Testing::Client.new(TestingSpec.app).accept(:json)

    json = client.post "/notes/7", json: {id: 7, title: "a"}
    json.json["via"].as_s.should eq "POST json"

    form = client.post "/notes/8", form: {"title" => "b"}
    form.json(TestingSpec::NoteResponse).should eq(form.json(TestingSpec::NoteResponse))
    form.json["id"].as_i.should eq 8
    form.json["via"].as_s.should eq "POST x-www-form-urlencoded"

    query = client.get "/notes/9", params: {title: "c"}
    query.json["title"].as_s.should eq "c"
  end

  it "builds the typed calls from the route of the endpoint" do
    client = Azu::Testing::Client.new(TestingSpec.app).accept(:json)
    request = TestingSpec::NoteRequest.new(5_i64, "typed")

    post = client.post(TestingSpec::SaveNote, request)
    post.status_code.should eq 201
    post.json(TestingSpec::NoteResponse).id.should eq 5

    get = client.get(TestingSpec::SaveNote, request)
    get.json["via"].as_s.should eq "GET plain"
    get.json["title"].as_s.should eq "typed"

    client.get(TestingSpec::SaveNote, id: 3, title: "named").json["id"].as_i.should eq 3
  end

  it "turns an exception that escapes the chain into a 500 and keeps the exception" do
    client = Azu::Testing::Client.new(TestingSpec.app, [] of HTTP::Handler)
    response = client.get "/boom"
    response.status_code.should eq 500
    response.error.try(&.message).should eq "kaput"
  end

  it "logs a client in through the in-memory session" do
    app = TestingSpec.app
    client = Azu::Testing::Client.new(app).login_with { |session| session["user"] = "ada" }
    client.get("/whoami").body.should contain "user=ada"
    Azu::Testing::Client.new(app).get("/whoami").body.should contain "user= "
  end

  it "sends a CSRF token for state-changing requests" do
    csrf = Azu::Handler::CSRF.new(secure_cookies: false)
    handlers = [csrf] of HTTP::Handler
    client = Azu::Testing::Client.new(TestingSpec.app, handlers)
    client.post("/redirect").status_code.should eq 403
    client.with_csrf.post("/redirect").status_code.should eq 303
  end

  it "keeps the session when a CSRF token is added to a logged-in client" do
    handlers = [Azu::Handler::CSRF.new(secure_cookies: false)] of HTTP::Handler
    client = Azu::Testing::Client.new(TestingSpec.app, handlers).login_with { |session| session["user"] = "ada" }.with_csrf
    client.post("/redirect").status_code.should eq 303
    client.get("/whoami").body.should contain "user=ada"
  end

  it "does not carry state to another client" do
    app = TestingSpec.app
    first = Azu::Testing::Client.new(app)
    first.headers["X-Mine"] = "1"
    first.get "/cookies"
    second = Azu::Testing::Client.new(app)
    second.cookies.to_h.should be_empty
    second.headers.has_key?("X-Mine").should be_false
  end

  it "talks to a channel over an in-memory WebSocket and sends the client's cookies" do
    client = Azu::Testing::Client.new(TestingSpec.app)
    socket = client.connect "/echo"
    socket.send "hi"
    socket.receive.should eq "echo:hi"
    socket.receive?(50.milliseconds).should be_nil
    socket.close
    TestingSpec::CLOSED.receive
    socket.closed?.should be_true
  end

  it "refuses a handshake to a path without a channel" do
    expect_raises(Azu::Testing::WebSocket::Rejected) { Azu::Testing::Client.new(TestingSpec.app).connect "/missing" }
  end
end

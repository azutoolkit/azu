require "../spec_helper"
require "http/client"
require "http/web_socket"

private GATE    = ::Channel(Nil).new
private ENTERED = ::Channel(Nil).new(8)

private struct SlowRequest
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    ENTERED.send(nil)
    GATE.receive
    context.response << "finished"
    context
  end
end

# A server-sent-events style response: it ends when the app starts shutting down.
private struct Events
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/event-stream"
    context.response << "data: hello\n\n"
    context.response.flush
    ENTERED.send(nil)
    select
    when Azu.shutdown_signal.receive?
      context.response << "data: bye\n\n"
    when timeout(30.seconds)
    end
    context
  end
end

# An SSE response that never looks at the shutdown signal.
private struct Deaf
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.flush
    ENTERED.send(nil)
    GATE.receive
    context
  end
end

private class Room < Azu::Channel
  def on_connect
    ENTERED.send(nil)
  end

  def on_message(message : String)
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

private def app_with_long_lived_routes : Azu::App
  app = Azu::App.new
  app.config.websocket.ping_interval = nil
  app.routes do
    get "/slow", SlowRequest
    get "/events", Events
    get "/deaf", Deaf
    ws "/room", Room
  end
  app
end

private def serve(app : Azu::App) : {String, Int32}
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  {address.address, address.port}
end

# Opens a socket and reports the close code the server sent.
private def open_socket(host : String, port : Int32) : ::Channel(HTTP::WebSocket::CloseCode?)
  codes = ::Channel(HTTP::WebSocket::CloseCode?).new(1)
  socket = HTTP::WebSocket.new(host, "/room", port)
  socket.on_close { |code, _| codes.send(code) }
  spawn { socket.run }
  ENTERED.receive
  codes
end

describe "graceful shutdown of long-lived connections" do
  it "closes an open WebSocket with 1001 and completes before the timeout" do
    app = app_with_long_lived_routes
    host, port = serve(app)
    codes = open_socket(host, port)

    started = Time.instant
    app.stop(10.seconds).should be_true
    (Time.instant - started).should be < 5.seconds

    codes.receive.should eq HTTP::WebSocket::CloseCode::GoingAway
  end

  it "ends a streaming response that listens for the shutdown signal" do
    app = app_with_long_lived_routes
    host, port = serve(app)
    body = ::Channel(String).new
    spawn { body.send HTTP::Client.get("http://#{host}:#{port}/events").body }
    ENTERED.receive

    app.stop(10.seconds).should be_true
    body.receive.should eq "data: hello\n\ndata: bye\n\n"
  end

  it "lets a normal request finish while a socket and a stream are closed, and refuses new ones with 503" do
    app = app_with_long_lived_routes
    host, port = serve(app)
    codes = open_socket(host, port)
    spawn { HTTP::Client.get("http://#{host}:#{port}/events") }
    ENTERED.receive
    other = HTTP::Client.new(host, port)
    other.get("/nothing-yet") # keeps a connection open for the 503 below
    body = ::Channel(String).new
    spawn { body.send HTTP::Client.get("http://#{host}:#{port}/slow").body }
    ENTERED.receive

    stopped = ::Channel(Bool).new
    spawn { stopped.send app.stop(10.seconds) }
    codes.receive.should eq HTTP::WebSocket::CloseCode::GoingAway
    other.get("/slow").status_code.should eq 503
    GATE.send(nil)

    stopped.receive.should be_true
    body.receive.should eq "finished"
  end

  it "waits at most the timeout for a response that ignores the shutdown signal" do
    app = app_with_long_lived_routes
    host, port = serve(app)
    spawn { HTTP::Client.get("http://#{host}:#{port}/deaf") rescue nil }
    ENTERED.receive

    app.stop(50.milliseconds).should be_false
    GATE.send(nil)
  end

  it "refuses to track a socket once shutdown began, and signals streams outside an app as running" do
    app = Azu::App.new
    app.track_socket(Room.new(HTTP::WebSocket.new(IO::Memory.new))) { }.should be_true
    app.begin_shutdown
    app.track_socket(Room.new(HTTP::WebSocket.new(IO::Memory.new))) { fail "ran" }.should be_false

    Azu.shutting_down?.should be_false
    Azu.with_app(app) { Azu.shutting_down?.should be_true }
  end
end

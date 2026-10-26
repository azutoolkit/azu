# Test WebSockets

This guide shows how to test `Azu::Channel`s and Spark live components. Channels are tested over a real
socket: an in-process `HTTP::Server` on a free port and `HTTP::WebSocket` as the client. That exercises
the handshake, the origin check, your callbacks and the PubSub wiring together. Components can also be
tested without any socket through `Azu::Spark::Testing`.

Specs normally use `Azu::Testing::Client#connect` (see [Testing](../../reference/api/testing.md#websocket)),
which performs the handshake through the app and exchanges frames over in-process pipes. The `WsClient` below,
which you keep in `spec/spec_helper.cr`, connects to a real port instead, which also exercises `HTTP::Server`'s
socket and connection handling.

## A client for specs

`HTTP::WebSocket` delivers messages to a callback and needs a fiber to run. The helper turns that into
`send` and `receive` with a timeout, so a missing message fails the example instead of hanging it.

```crystal
require "spec"
require "azu"
require "http/client"
require "http/web_socket"

# Collects the text frames the server sends.
class WsClient
  getter close_code : HTTP::WebSocket::CloseCode? = nil

  def initialize(port : Int32, path : String = "/", origin : String? = nil)
    headers = HTTP::Headers.new
    headers["Origin"] = origin if origin
    @messages = ::Channel(String).new(64)
    @socket = HTTP::WebSocket.new("127.0.0.1", path, port, headers: headers)
    @socket.on_message { |message| @messages.send(message) }
    @socket.on_close do |code, _|
      @close_code = code
      @messages.close
    end
    spawn do
      @socket.run
    rescue IO::Error
      # The server dropped the connection during the close handshake.
    end
  end

  def send(message : String) : Nil
    @socket.send(message)
  end

  # The next text frame, or nil when the socket closed or the timeout passed.
  def receive(timeout : Time::Span = 2.seconds) : String?
    select
    when message = @messages.receive?
      message
    when timeout(timeout)
      nil
    end
  end

  def close : Nil
    @socket.close
  end
end

# Serves *app* on a free port while the block runs.
def serve(app : Azu::App, &)
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

class EchoChannel < Azu::Channel
  def on_connect
    send "welcome"
  end

  def on_message(message : String)
    send "echo: #{message}"
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

describe EchoChannel do
  it "greets and echoes" do
    app = Azu::App.new
    app.routes { ws "/echo", EchoChannel }

    serve(app) do |port|
      client = WsClient.new(port, "/echo")
      client.receive.should eq "welcome"

      client.send "hello"
      client.receive.should eq "echo: hello"

      client.close
    end
  end
end
```

Registering the channel on a fresh `Azu::App` keeps specs isolated. A channel that declares
`ws "/path"` in its class body registers on the default app, which you serve with
`serve(Azu::App.default)`.

## Testing broadcasting

Two clients subscribed to the same topic both receive a broadcast. A message sent to a topic from the
spec itself goes through `Azu::PubSub`, like a broadcast from an endpoint or a job would.

```crystal
require "spec"
require "azu"
require "http/web_socket"

class WsClient
  def initialize(port : Int32, path : String)
    @messages = ::Channel(String).new(64)
    @socket = HTTP::WebSocket.new("127.0.0.1", path, port)
    @socket.on_message { |message| @messages.send(message) }
    spawn do
      @socket.run
    rescue IO::Error
    end
  end

  def send(message : String) : Nil
    @socket.send(message)
  end

  def receive(timeout : Time::Span = 2.seconds) : String?
    select
    when message = @messages.receive?
      message
    when timeout(timeout)
      nil
    end
  end

  def close : Nil
    @socket.close
  end
end

def serve(app : Azu::App, &)
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

class RoomChannel < Azu::Channel
  def on_connect
    subscribe topic
    send "joined #{room}"
  end

  def on_message(message : String)
    broadcast topic, message
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end

  private def room : String
    context.request.path_params["room"]
  end

  private def topic : String
    "room:#{room}"
  end
end

describe RoomChannel do
  it "delivers a message to everyone in the room, and only to them" do
    app = Azu::App.new
    app.routes { ws "/rooms/:room", RoomChannel }

    serve(app) do |port|
      ada = WsClient.new(port, "/rooms/general")
      grace = WsClient.new(port, "/rooms/general")
      outsider = WsClient.new(port, "/rooms/random")
      [ada, grace, outsider].each(&.receive) # "joined ..."

      ada.send "hi all"

      ada.receive.should eq "hi all"
      grace.receive.should eq "hi all"
      outsider.receive(200.milliseconds).should be_nil

      [ada, grace, outsider].each(&.close)
    end
  end

  it "receives broadcasts that come from outside a channel" do
    app = Azu::App.new
    app.routes { ws "/rooms/:room", RoomChannel }

    serve(app) do |port|
      client = WsClient.new(port, "/rooms/general")
      client.receive.should eq "joined general"

      Azu::PubSub.broadcast("room:general", {event: "deploy"})

      client.receive.should eq %({"event":"deploy"})
      client.close
    end
  end
end
```

Messages are asserted by waiting for them (`receive` with a timeout) and "nothing arrived" is asserted
with a short timeout. Avoid fixed `sleep`s.

## Testing authentication and refusals

A channel that refuses a client closes with a code you can assert on. The origin check happens before
the upgrade, so a foreign origin fails the handshake with 403:

```crystal
require "spec"
require "azu"
require "http/web_socket"

def serve(app : Azu::App, &)
  server = app.server
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

class PrivateChannel < Azu::Channel
  def on_connect
    unless params["token"]? == "let-me-in"
      close(HTTP::WebSocket::CloseCode::PolicyViolation, "Unauthorized")
      return
    end
    send "authenticated"
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

describe PrivateChannel do
  it "accepts a valid token" do
    app = Azu::App.new
    app.routes { ws "/private", PrivateChannel }

    serve(app) do |port|
      messages = ::Channel(String).new(4)
      socket = HTTP::WebSocket.new("127.0.0.1", "/private?token=let-me-in", port)
      socket.on_message { |message| messages.send(message) }
      spawn { socket.run rescue nil }

      messages.receive.should eq "authenticated"
      socket.close
    end
  end

  it "closes the connection for a bad token" do
    app = Azu::App.new
    app.routes { ws "/private", PrivateChannel }

    serve(app) do |port|
      closed = ::Channel({HTTP::WebSocket::CloseCode?, String?}).new(1)
      socket = HTTP::WebSocket.new("127.0.0.1", "/private?token=wrong", port)
      socket.on_close { |code, reason| closed.send({code, reason}) }
      spawn { socket.run rescue nil }

      code, reason = closed.receive
      code.should eq HTTP::WebSocket::CloseCode::PolicyViolation
      reason.should eq "Unauthorized"
    end
  end

  it "refuses a foreign origin before upgrading" do
    app = Azu::App.new
    app.routes { ws "/private", PrivateChannel }

    serve(app) do |port|
      headers = HTTP::Headers{"Origin" => "https://evil.example"}

      expect_raises(Socket::Error, /403/) do
        HTTP::WebSocket.new("127.0.0.1", "/private?token=let-me-in", port, headers: headers)
      end
    end
  end
end
```

Clients without an `Origin` header (like these specs) are accepted; browsers always send one. To test an
allowed cross-origin client, add the origin to `Azu::CONFIG.websocket.allowed_origins` for the example
and restore it afterwards.

## Testing PubSub on its own

Logic that publishes does not need a socket. Subscribe in the spec and assert on what arrives:

```crystal
require "spec"
require "azu"

def announce(text : String) : Nil
  Azu::PubSub.broadcast("announcements", {type: "announcement", text: text})
end

describe "announce" do
  it "publishes JSON to the announcements topic" do
    received = ::Channel(Azu::PubSub::Message).new(1)
    subscription = Azu::PubSub.subscribe("announcements") { |message| received.send(message) }

    announce("Deploy at noon")

    message = received.receive
    message.topic.should eq "announcements"
    JSON.parse(message.payload)["text"].should eq "Deploy at noon"
    subscription.cancel
  end
end
```

With the in-memory backend the handler runs before `broadcast` returns, but waiting on a channel keeps
the spec correct for the Redis backend too.

## Testing Spark components

`Azu::Spark::Testing` mounts a component with a real session and no WebSocket. `trigger` sends a client
event, `broadcast` and `send_info` deliver messages to `handle_info`, `html` is what the browser would
show and `assigns` the typed state.

```crystal
require "spec"
require "azu"

class Chat < Azu::Spark::Component
  state lines : Array(String) = [] of String

  def mount(socket : Azu::Spark::Socket, params : Azu::Spark::Params) : Nil
    socket.subscribe("chat")
  end

  def handle_info(message : Azu::PubSub::Message, socket : Azu::Spark::Socket) : Nil
    self.lines = lines + [message.payload]
  end

  event def say(text : String) : Nil
    socket.broadcast("chat", text)
  end

  def render
    ul { lines.each { |line| li line } }
  end
end

describe Chat do
  it "shows what is said, in every mounted view" do
    Azu::Spark::Testing.mount(Chat) do |ada|
      Azu::Spark::Testing.mount(Chat) do |grace|
        ada.trigger("say", text: "hello")
        grace.settle

        ada.html.should contain "<li>hello</li>"
        grace.assigns[:lines].should eq ["hello"]
      end
    end
  end

  it "reacts to a broadcast from outside" do
    Azu::Spark::Testing.mount(Chat) do |view|
      view.broadcast("chat", "from a job")

      view.html.should contain "from a job"
    end
  end

  it "rejects events that are not declared with event def" do
    Azu::Spark::Testing.mount(Chat) do |view|
      expect_raises(Azu::Spark::UnknownEvent) { view.trigger("render") }
    end
  end
end
```

## Testing the live connection

To test the real protocol, render a page, take the signed token out of it and speak the wire format over
a socket. Frames are JSON objects `{"v": 1, "type": ...}`: the server greets with `hello`, you send
`join` with the token, then `event` frames, and the server answers with `diff` frames carrying the
patched HTML.

```crystal
require "spec"
require "azu"
require "http/web_socket"

class Counter < Azu::Spark::Component
  mountable

  state count : Int32 = 0

  event def increment : Nil
    self.count += 1
  end

  def render
    button "Count: #{count}", **spark_click(:increment)
  end
end

describe "Spark over a socket" do
  it "joins with the page token and applies an event" do
    app = Azu::App.new
    Azu::Spark.install(app.router)
    server = app.server
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    begin
      page = Azu.with_config(app.config) { Azu::Spark.render(Counter) }
      token = page.match!(/data-spark-token='([^']+)'/)[1]
      root = page.match!(/data-spark-id='([^']+)'/)[1]

      frames = ::Channel(JSON::Any).new(16)
      socket = HTTP::WebSocket.new("127.0.0.1", Azu::Spark.config.path, address.port)
      socket.on_message { |text| frames.send(JSON.parse(text)) }
      spawn { socket.run rescue nil }

      # Reads frames until one of the given type arrives; fails instead of hanging.
      await = ->(type : String) do
        loop do
          select
          when frame = frames.receive
            break frame if frame["type"].as_s == type
          when timeout(2.seconds)
            raise "no #{type} frame arrived"
          end
        end
      end

      await.call("hello")
      socket.send({v: 1, type: "join", id: 1, token: token}.to_json)
      await.call("diff")["patches"][0]["html"].as_s.should contain "Count: 0"

      socket.send({v: 1, type: "event", id: 2, target: root, event: "increment", payload: {} of String => String}.to_json)
      await.call("diff")["patches"][0]["html"].as_s.should contain "Count: 1"

      socket.close
    ensure
      server.close
    end
  end
end
```

The token is signed with the Spark secret of the app that serves the connection. Inside an endpoint
that is automatic; a spec that calls `Azu::Spark.render` itself does it in the scope of the app, as above,
because every `Azu::App` has its own configuration. Outside production and staging a random secret is
generated per configuration, so the spec needs no setup.

## Running the specs

```bash
crystal spec spec/channels
crystal spec spec/channels/room_channel_spec.cr:55
```

## See also

- [Testing Endpoints](test-endpoints.md)
- [Create a WebSocket channel](../real-time/create-websocket-channel.md)
- [Build a live component](../real-time/build-live-component.md)
- [Channel Reference](../../reference/api/channel.md)

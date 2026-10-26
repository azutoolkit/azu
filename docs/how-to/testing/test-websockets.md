---
description: "Test `Azu::Channel`s and Spark live components with `Azu::Testing`: messages, broadcasts, refusals and the Spark wire protocol."
---

# Test WebSockets

`require "azu/testing"` loads `Azu::Testing::Client`, whose `connect` performs the WebSocket handshake by calling
the app's handler chain and router in process and returns an `Azu::Testing::WebSocket`; the frames travel over
in-process pipes, so no port is bound. That exercises the handshake, the origin check, your callbacks and the
PubSub wiring together. Components can also be tested without any socket through `Azu::Spark::Testing`. The
client's API is on [Testing](../../reference/api/testing.md#websocket).

## Connect and exchange messages

```crystal
require "spec"
require "azu"
require "azu/testing"

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

    socket = Azu::Testing::Client.new(app).connect "/echo"
    socket.receive.should eq "welcome"

    socket.send "hello"
    socket.receive.should eq "echo: hello"
    socket.receive?(100.milliseconds).should be_nil

    socket.close
    socket.closed?.should be_true
  end
end
```

`receive` waits up to two seconds for the next text frame and raises `Azu::Testing::WebSocket::Timeout` when none
arrives (`Closed` once the socket is closed), so a missing message fails the example instead of hanging it.
`receive?` returns `nil` instead, which is how you assert that nothing arrived. `close` sends a close frame and
waits for the channel's `on_close`.

Registering the channel on a fresh `Azu::App` keeps specs isolated. A channel that declares `ws "/path"` in its
class body registers on `Azu::App.default`, which `Azu::Testing::Client.new` uses when you pass no app.

## Test broadcasting

Each `connect` opens a separate connection, with the client's cookies. Two connections subscribed to the same
topic both receive a broadcast. A message sent to a topic from the spec itself goes
through `Azu::PubSub`, like a broadcast from an endpoint or a job would.

```crystal
require "spec"
require "azu"
require "azu/testing"

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
    client = Azu::Testing::Client.new(app)

    ada = client.connect "/rooms/general"
    grace = client.connect "/rooms/general"
    outsider = client.connect "/rooms/random"
    [ada, grace, outsider].each(&.receive) # "joined ..."

    ada.send "hi all"

    ada.receive.should eq "hi all"
    grace.receive.should eq "hi all"
    outsider.receive?(200.milliseconds).should be_nil

    [ada, grace, outsider].each(&.close)
  end

  it "receives broadcasts that come from outside a channel" do
    app = Azu::App.new
    app.routes { ws "/rooms/:room", RoomChannel }

    socket = Azu::Testing::Client.new(app).connect "/rooms/general"
    socket.receive.should eq "joined general"

    Azu::PubSub.broadcast("room:general", {event: "deploy"})

    socket.receive.should eq %({"event":"deploy"})
    socket.close
  end
end
```

Messages are asserted by waiting for them and "nothing arrived" with a short `receive?` timeout. Avoid fixed
`sleep`s.

## Test authentication and refusals

`connect` sends the client's cookies with the handshake, so a client logged in with `login_with` reaches the
channel with its session. A channel that refuses a client closes the socket with a code you can assert on. The
origin check happens before the upgrade, so a foreign origin fails the handshake and `connect` raises
`Azu::Testing::WebSocket::Rejected`, which carries the app's answer:

```crystal
require "spec"
require "azu"
require "azu/testing"

class PrivateChannel < Azu::Channel
  def on_connect
    user = Azu.session_adapter.try(&.session(context)["user_id"]?)
    unless user
      close(HTTP::WebSocket::CloseCode::PolicyViolation, "Unauthorized")
      return
    end
    send "hello #{user}"
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

def private_app : Azu::App
  app = Azu::App.new
  app.routes { ws "/private", PrivateChannel }
  app
end

describe PrivateChannel do
  it "accepts a logged-in client" do
    Azu::Testing::Client.open(private_app) do |client|
      client.login_with { |session| session["user_id"] = "7" }

      socket = client.connect "/private"
      socket.receive.should eq "hello 7"
      socket.close
    end
  end

  it "closes the connection for a client without a session" do
    socket = Azu::Testing::Client.new(private_app).connect "/private"

    socket.receive?.should be_nil
    socket.close_code.should eq HTTP::WebSocket::CloseCode::PolicyViolation
  end

  it "refuses a foreign origin before upgrading" do
    client = Azu::Testing::Client.new(private_app)

    error = expect_raises(Azu::Testing::WebSocket::Rejected) do
      client.connect "/private", headers: {"Origin" => "https://evil.example"}
    end
    error.response.status_code.should eq 403
  end

  it "accepts an origin the app allows" do
    app = private_app
    app.config.websocket.allowed_origins << "https://app.example"

    Azu::Testing::Client.open(app) do |client|
      client.login_with { |session| session["user_id"] = "7" }

      socket = client.connect "/private", headers: {"Origin" => "https://app.example"}
      socket.receive.should eq "hello 7"
      socket.close
    end
  end
end
```

The client sends no `Origin` header unless you pass one, and a handshake without one is accepted; browsers
always send one. `Client.open` closes the client when the block ends, which removes the in-memory session
adapter `login_with` installed on the app.

## Test PubSub on its own

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

## Test Spark components

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

## Test the live connection

To test the real protocol, render a page, take the signed token out of it and speak the wire format over
a connection to `Azu::Spark.config.path`. Frames are JSON objects `{"v": 1, "type": ...}`: the app greets with
`hello`, you send `join` with the token, then `event` frames, and the app answers with `diff` frames carrying the
patched HTML.

```crystal
require "spec"
require "azu"
require "azu/testing"

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

# Reads frames until one of *type* arrives; `receive` raises after two seconds without one.
def await_frame(socket : Azu::Testing::WebSocket, type : String) : JSON::Any
  loop do
    frame = JSON.parse(socket.receive)
    return frame if frame["type"].as_s == type
  end
end

describe "Spark over a socket" do
  it "joins with the page token and applies an event" do
    app = Azu::App.new
    Azu::Spark.install(app.router)

    page = Azu.with_config(app.config) { Azu::Spark.render(Counter) }
    token = page.match!(/data-spark-token='([^']+)'/)[1]
    root = page.match!(/data-spark-id='([^']+)'/)[1]

    socket = Azu::Testing::Client.new(app).connect(Azu::Spark.config.path)
    await_frame(socket, "hello")

    socket.send({v: 1, type: "join", id: 1, token: token}.to_json)
    await_frame(socket, "diff")["patches"][0]["html"].as_s.should contain "Count: 0"

    socket.send({v: 1, type: "event", id: 2, target: root, event: "increment", payload: {} of String => String}.to_json)
    await_frame(socket, "diff")["patches"][0]["html"].as_s.should contain "Count: 1"

    socket.close
  end
end
```

The token is signed with the Spark secret of the app that accepts the connection. Inside an endpoint that is
automatic; a spec that calls `Azu::Spark.render` itself does it in the scope of the app, as above, because every
`Azu::App` has its own configuration. Outside production and staging a random secret is generated per
configuration, so the spec needs no setup.

## See also

- [Testing](../../reference/api/testing.md)
- [Channel](../../reference/api/channel.md)
- [Test endpoints](test-endpoints.md)
- [Spark live views](../../explanation/spark-live-views.md)

---
description: "Write tests for an Azu application: endpoints, request contracts, WebSocket channels and live components."
---

# Testing your app

Every example runs with the tools that ship with Crystal
(`spec`, `HTTP::Server`, `HTTP::Client`, `HTTP::WebSocket`) and with Azu's own `Azu::App` and
`Azu::Spark::Testing`.

## What you'll learn

By the end of this tutorial, you'll be able to:

- Set up a spec helper that serves your app in-process
- Test endpoints through the real handler chain
- Test request validation
- Test WebSocket channels and PubSub
- Test live (Spark) components
- Organise and run your specs

## Prerequisites

- Completed the previous tutorials (the examples use a small user API like the one you built)
- Basic understanding of testing concepts
- Crystal 1.19.1 or newer

{% hint style="info" %}
Specs normally use `Azu::Testing::Client` (see [Testing](../reference/api/testing.md)), which sends requests and
WebSocket frames through the app's real handler chain and router without opening a socket. The helpers below serve
the app on a real port instead, which also exercises `HTTP::Server`'s socket and connection handling; for
everything else the client replaces them.
{% endhint %}

## Step 1: Test setup

Create `spec/spec_helper.cr`. It loads the application and defines the two helpers the rest of the
tutorial uses: `serve` runs an app on a free local port, and `WsClient` talks to it over a WebSocket.

{% code title="spec/spec_helper.cr" %}
```crystal
require "spec"
require "azu"
require "http/client"
require "http/web_socket"

# Runs *app* on a free local port while the block executes and yields an HTTP client for it.
# Endpoints declared with get/post/... register on Azu::App.default.
def serve(app : Azu::App = Azu::App.default, &)
  handlers = [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new] of HTTP::Handler
  server = app.server(handlers)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

# A WebSocket client that collects the text frames the server sends.
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

  # The next frame, or nil when the timeout passes.
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
```
{% endcode %}

`serve` builds the handler chain with `RequestId` (so responses carry `X-Request-ID`) and `Rescuer`
(so errors raised in `call` become the 404 or 401 responses clients see; a request that breaks its contract is
answered with 400 or 422 by the endpoint itself). In a real project each spec file
starts with `require "./spec_helper"` and the application file.

## Step 2: Testing endpoints

An endpoint spec starts the app, makes a real request and checks the response.

```crystal
require "spec"
require "azu"
require "http/client"

def serve(app : Azu::App = Azu::App.default, &)
  server = app.server([Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

USERS = {} of Int64 => {name: String, email: String}

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
end

struct UserResponse
  include Azu::Response

  def initialize(@id : Int64, @name : String, @email : String)
  end

  def render
    {id: @id, name: @name, email: @email}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    user = create_user_request
    id = USERS.size.to_i64 + 1
    USERS[id] = {name: user.name, email: user.email}
    status 201
    content_type "application/json"
    UserResponse.new(id, user.name, user.email)
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    id = params["id"].to_i64
    user = USERS[id]? || raise Azu::Response::NotFound.new("/users/#{id}")
    content_type "application/json"
    UserResponse.new(id, user[:name], user[:email])
  end
end

describe "users API" do
  json = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}

  before_each { USERS.clear }

  describe "POST /users" do
    it "creates a user" do
      serve do |client|
        response = client.post "/users", headers: json, body: {name: "Ada", email: "ada@example.com"}.to_json

        response.status_code.should eq 201
        JSON.parse(response.body)["name"].should eq "Ada"
        USERS.size.should eq 1
      end
    end

    it "does not run the endpoint for an invalid body" do
      serve do |client|
        response = client.post "/users", headers: json, body: {name: "A", email: "nope"}.to_json

        response.status_code.should eq 422
        USERS.should be_empty
      end
    end
  end

  describe "GET /users/:id" do
    it "returns the user" do
      USERS[1_i64] = {name: "Ada", email: "ada@example.com"}

      serve do |client|
        response = client.get "/users/1", headers: json

        response.status_code.should eq 200
        JSON.parse(response.body)["email"].should eq "ada@example.com"
      end
    end

    it "answers 404 for an unknown user" do
      serve do |client|
        client.get("/users/42", headers: json).status_code.should eq 404
      end
    end
  end
end
```

Things to notice:

- The endpoint structs register their routes when they are defined, so the spec only has to load them.
- Requests are real HTTP requests, so status codes, headers and content negotiation are what a client sees.
- State kept in module-level variables (`USERS`) is cleared in `before_each`; with a database, truncate
  or roll back in the same place.

See [How to test endpoints](../how-to/testing/test-endpoints.md) for PUT, DELETE, authentication and apps
built as values.

## Step 3: Testing request validation

A request contract is enforced before the endpoint runs: a body that fails validation is answered with
`422` and a problem document listing the broken fields. You can test the contract with
or without HTTP.

```crystal
require "spec"
require "azu"

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32 = 18

  def initialize(@name = "", @email = "", @age = 18)
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
  validate age, gt: 0, lt: 150
end

describe CreateUserRequest do
  it "accepts valid input" do
    CreateUserRequest.new("Ada", "ada@example.com", 36).valid?.should be_true
  end

  it "rejects a missing name" do
    request = CreateUserRequest.new("", "ada@example.com")

    request.valid?.should be_false
    request.errors.map(&.field).should contain :name
  end

  it "rejects a malformed email" do
    CreateUserRequest.new("Ada", "not-an-email").valid?.should be_false
  end

  it "rejects an age outside the range" do
    CreateUserRequest.new("Ada", "ada@example.com", 200).valid?.should be_false
  end

  it "is built from a JSON body the way an endpoint builds it" do
    request = CreateUserRequest.from_json(%({"name": "Ada", "email": "ada@example.com"}))

    request.name.should eq "Ada"
    request.age.should eq 18
  end

  it "is built from form data" do
    request = CreateUserRequest.from_www_form("name=Ada&email=ada%40example.com")

    request.email.should eq "ada@example.com"
  end
end
```

## Step 4: Testing WebSocket channels

A channel is tested over a real socket, which exercises the handshake and your callbacks together. Register
the channel on a fresh `Azu::App` so the spec is isolated:

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

class NotificationChannel < Azu::Channel
  def on_connect
    subscribe "notifications"
    send({type: "connected"}.to_json)
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

describe NotificationChannel do
  it "welcomes a client and forwards broadcasts" do
    app = Azu::App.new
    app.routes { ws "/notifications", NotificationChannel }
    server = app.server
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    begin
      client = WsClient.new(address.port, "/notifications")
      client.receive.should eq %({"type":"connected"})

      Azu::PubSub.broadcast("notifications", {type: "user_created", name: "Ada"})

      JSON.parse(client.receive.not_nil!)["name"].should eq "Ada"
      client.close
    ensure
      server.close
    end
  end

  it "does not deliver other topics" do
    app = Azu::App.new
    app.routes { ws "/notifications", NotificationChannel }
    server = app.server
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    begin
      client = WsClient.new(address.port, "/notifications")
      client.receive # the welcome message

      Azu::PubSub.broadcast("other", "ignored")

      client.receive(200.milliseconds).should be_nil
      client.close
    ensure
      server.close
    end
  end
end
```

Wait for messages with `receive` (which times out) rather than sleeping, and assert "nothing arrived" with
a short timeout. [How to test WebSockets](../how-to/testing/test-websockets.md) covers authentication,
origin checks and the Spark wire protocol.

## Step 5: Testing live components

`Azu::Spark::Testing` mounts a component with a real session and no socket, so you test state, events and
rendering directly:

```crystal
require "spec"
require "azu"

class Counter < Azu::Spark::Component
  prop label : String = "Clicks"
  state count : Int32 = 0

  event def increment(by : Int32 = 1) : Nil
    self.count += by
  end

  def render
    h2 "#{label}: #{count}"
  end
end

describe Counter do
  it "starts at zero" do
    Azu::Spark::Testing.mount(Counter) do |view|
      view.html.should contain "Clicks: 0"
    end
  end

  it "counts events" do
    Azu::Spark::Testing.mount(Counter, label: "Hits") do |view|
      view.trigger("increment")
      view.trigger("increment", by: 5)

      view.html.should contain "Hits: 6"
      view.assigns[:count].should eq 6
    end
  end

  it "rejects a payload of the wrong type" do
    Azu::Spark::Testing.mount(Counter) do |view|
      expect_raises(Azu::Spark::BadRequest) { view.trigger("increment", by: "lots") }
      view.assigns[:count].should eq 0
    end
  end
end
```

## Step 6: Integration tests

An integration spec drives several requests through the same stack `Azu.start` builds. Use
`app.default_handlers` for the full default chain (request id, logging, error pages, security headers,
static files):

```crystal
require "spec"
require "azu"
require "http/client"

struct StatusResponse
  include Azu::Response

  def render
    {status: "ok"}.to_json
  end
end

struct StatusEndpoint
  include Azu::Endpoint(Azu::Request, StatusResponse)

  get "/status"

  def call : StatusResponse
    content_type "application/json"
    StatusResponse.new
  end
end

describe "the default stack" do
  it "serves the API with its security headers and request id" do
    app = Azu::App.default
    server = app.server(app.default_handlers)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    begin
      client = HTTP::Client.new(address.address, address.port)
      response = client.get "/status", headers: HTTP::Headers{"Accept" => "application/json"}

      response.status_code.should eq 200
      response.headers["X-Request-ID"]?.should_not be_nil
      response.headers["X-Content-Type-Options"]?.should eq "nosniff"
      client.get("/missing", headers: HTTP::Headers{"Accept" => "application/json"}).status_code.should eq 404
    ensure
      app.stop(1.second)
    end
  end
end
```

`app.stop` closes the server, sends every open WebSocket a close frame with code 1001 (going away) and waits,
up to the timeout, for the requests in flight and for those sockets to close, as a graceful shutdown does (see
[Shut down gracefully](../how-to/deployment/graceful-shutdown.md)).

## Step 7: Running tests

```bash
crystal spec                              # everything
crystal spec spec/endpoints               # one directory
crystal spec spec/users_spec.cr:12        # one example, by line
crystal spec --tag focus                  # examples tagged focus: true
crystal spec --verbose                    # print every example
crystal spec --order random               # shuffle, to find hidden dependencies
```

## Test organization

```text
spec/
├── spec_helper.cr           # serve, WsClient, shared setup
├── endpoints/               # endpoint specs (real requests)
├── requests/                # request contract specs
├── services/                # plain Crystal specs
├── channels/                # WebSocket channel specs
├── components/              # Spark component specs
└── integration/             # whole-stack specs
```

## Best practices

1. **Start servers on a free port** (`bind_unused_port`) so specs can run side by side, and close them in `ensure`.
2. **Never sleep to wait for something**; wait on a `Channel` with a timeout.
3. **Reset shared state** (module variables, the database, PubSub subscriptions) in `before_each`.
4. **Keep logic out of endpoints** so most specs need no server.

## Next steps

{% content-ref url="../how-to/testing/test-endpoints.md" %}
[test-endpoints.md](../how-to/testing/test-endpoints.md)
{% endcontent-ref %}

{% content-ref url="../how-to/testing/test-websockets.md" %}
[test-websockets.md](../how-to/testing/test-websockets.md)
{% endcontent-ref %}

{% content-ref url="deploying-to-production.md" %}
[deploying-to-production.md](deploying-to-production.md)
{% endcontent-ref %}

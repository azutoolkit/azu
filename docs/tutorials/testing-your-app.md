---
description: "Write tests for an Azu application: endpoints, request contracts, WebSocket channels and live components."
---

# Testing your app

The examples use Crystal's `spec` and `Azu::Testing`, the test harness Azu ships. `require "azu/testing"` loads
`Azu::Testing::Client`, which sends HTTP requests and WebSocket frames to your app by calling its handler chain
and router in process: no port is bound, yet each request goes through real handlers, the router and the request
contracts. Live components are tested with `Azu::Spark::Testing`.

## What you'll learn

By the end of this tutorial, you'll be able to:

- Set up a spec helper that loads `Azu::Testing`
- Test endpoints through the real handler chain
- Test request validation
- Test WebSocket channels and PubSub
- Test live (Spark) components
- Check the app on a real port
- Organise and run your specs

## Prerequisites

- Completed the previous tutorials (the examples use a small user API like the one you built)
- Basic understanding of testing concepts
- Crystal 1.22.1 or newer

## Step 1: Test setup

Create `spec/spec_helper.cr`. It loads Crystal's spec library, Azu and its test harness:

{% code title="spec/spec_helper.cr" %}
```crystal
require "spec"
require "azu"
require "azu/testing"
```
{% endcode %}

Add `require "../src/your_app"` (your application's main file) after these lines, and start every spec file with
`require "./spec_helper"`. The examples below repeat the requires so each one runs on its own.

`Azu::Testing::Client.new` drives `Azu::App.default`, where endpoints declared with `get`, `post` and the other
verb macros register, through two handlers: `RequestId` (so responses carry `X-Request-ID`) and `Rescuer` (so
errors raised in `call` become the 404 or 401 responses clients see). A request that breaks its contract is
answered with 400 or 422 by the endpoint itself.

## Step 2: Testing endpoints

The user API from the previous tutorials, reduced to two endpoints:

<!-- prelude -->
{% code title="src/users.cr" %}
```crystal
require "azu"

USERS = {} of Int64 => {name: String, email: String}

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

struct UserResponse
  include Azu::Response
  include JSON::Serializable

  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id : Int64, @name : String, @email : String)
  end

  def render
    to_json
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
```
{% endcode %}

An endpoint spec makes a request with the client and checks the response:

{% code title="spec/users_spec.cr" %}
```crystal
require "spec"
require "azu"
require "azu/testing"

describe "users API" do
  before_each { USERS.clear }

  describe "POST /users" do
    it "creates a user" do
      client = Azu::Testing::Client.new.accept(:json)
      response = client.post "/users", json: {name: "Ada", email: "ada@example.com"}

      response.status_code.should eq 201
      response.json(UserResponse).name.should eq "Ada"
      USERS.size.should eq 1
    end

    it "takes the endpoint's own contract" do
      client = Azu::Testing::Client.new.accept(:json)
      response = client.post(CreateUserEndpoint, name: "Grace", email: "grace@example.com")

      response.status_code.should eq 201
      response.json(UserResponse).id.should eq 1
    end

    it "does not run the endpoint for an invalid body" do
      client = Azu::Testing::Client.new.accept(:json)
      response = client.post "/users", json: {name: "A", email: "nope"}

      response.status_code.should eq 422
      response.problem?.should be_true
      USERS.should be_empty
    end
  end

  describe "GET /users/:id" do
    it "returns the user" do
      USERS[1_i64] = {name: "Ada", email: "ada@example.com"}
      response = Azu::Testing::Client.new.accept(:json).get "/users/1"

      response.status_code.should eq 200
      response.json["email"].should eq "ada@example.com"
    end

    it "answers 404 for an unknown user" do
      Azu::Testing::Client.new.accept(:json).get("/users/42").status_code.should eq 404
    end
  end
end
```
{% endcode %}

Things to notice:

- The endpoint structs register their routes when they are defined, so the spec only has to load them.
- `accept(:json)` sets the `Accept` header of every request of that client, and `json:` sends a JSON body.
- `client.post(CreateUserEndpoint, name: ..., email: ...)` takes the path from the endpoint's route; the
  response's `json(UserResponse)` parses the body back into the response type.
- State kept in module-level variables (`USERS`) is cleared in `before_each`; with a database, truncate
  or roll back in the same place.

See [Test endpoints](../how-to/testing/test-endpoints.md) for PUT, DELETE, sessions, CSRF, redirects and time.

## Step 3: Testing request validation

A request contract is enforced before the endpoint runs: a body that fails validation is answered with
`422` and a problem document listing the broken fields, as the last POST example shows. The contract can also be
tested without a request:

{% code title="spec/create_user_request_spec.cr" %}
```crystal
require "spec"
require "azu"

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
{% endcode %}

## Step 4: Testing WebSocket channels

`client.connect` performs the WebSocket handshake through the app and returns a socket whose frames travel over
in-process pipes, which exercises the handshake and your callbacks together. Register the channel on a fresh
`Azu::App` so the spec is isolated:

{% code title="spec/notification_channel_spec.cr" %}
```crystal
require "spec"
require "azu"
require "azu/testing"

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

    socket = Azu::Testing::Client.new(app).connect "/notifications"
    socket.receive.should eq %({"type":"connected"})

    Azu::PubSub.broadcast("notifications", {type: "user_created", name: "Ada"})

    JSON.parse(socket.receive)["name"].should eq "Ada"
    socket.close
  end

  it "does not deliver other topics" do
    app = Azu::App.new
    app.routes { ws "/notifications", NotificationChannel }

    socket = Azu::Testing::Client.new(app).connect "/notifications"
    socket.receive # the welcome message

    Azu::PubSub.broadcast("other", "ignored")

    socket.receive?(200.milliseconds).should be_nil
    socket.close
  end
end
```
{% endcode %}

`receive` waits up to two seconds for the next frame and raises when none arrives, so wait with it rather than
sleeping, and assert "nothing arrived" with `receive?` and a short timeout.
[Test WebSockets](../how-to/testing/test-websockets.md) covers authentication, origin checks and the Spark wire
protocol.

## Step 5: Testing live components

`Azu::Spark::Testing` mounts a component with a real session and no socket, so you test state, events and
rendering directly:

{% code title="spec/counter_spec.cr" %}
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
{% endcode %}

## Step 6: Checking the app on a real port

The client never opens a socket, so it does not exercise what `HTTP::Server` does itself: parsing the request
line, keep-alive and connection handling. Keep one spec that binds the app to a free port with the handlers
`Azu.start` uses (`app.default_handlers`) and talks to it with `HTTP::Client`:

{% code title="spec/integration/real_port_spec.cr" %}
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

  def call : StatusResponse
    content_type "application/json"
    StatusResponse.new
  end
end

describe "the app on a real port" do
  it "answers over one keep-alive connection with the default stack" do
    app = Azu::App.new
    app.routes { get "/status", StatusEndpoint }
    server = app.server(app.default_handlers)
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }

    begin
      client = HTTP::Client.new(address.address, address.port)
      headers = HTTP::Headers{"Accept" => "application/json"}
      response = client.get "/status", headers: headers

      response.status_code.should eq 200
      response.headers["X-Request-ID"]?.should_not be_nil
      response.headers["X-Content-Type-Options"]?.should eq "nosniff"
      client.get("/missing", headers: headers).status_code.should eq 404
    ensure
      app.stop(1.second)
    end
  end
end
```
{% endcode %}

`app.stop` stops accepting connections, sends every open WebSocket a close frame with code 1001 (going away) and waits, up
to the timeout, for the requests in flight and for those sockets to close, as a graceful shutdown does (see
[Shut down gracefully](../how-to/deployment/graceful-shutdown.md)).

{% hint style="warning" %}
A stopped app answers every later request with 503, from the client too. Build a fresh `Azu::App` for this spec,
as above, rather than stopping `Azu::App.default`, which the other specs use.
{% endhint %}

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
├── spec_helper.cr           # requires spec, azu, azu/testing and the app
├── endpoints/               # endpoint specs (Azu::Testing::Client)
├── requests/                # request contract specs
├── services/                # plain Crystal specs
├── channels/                # WebSocket channel specs
├── components/              # Spark component specs
└── integration/             # the real-port spec
```

## Best practices

1. **Build a client per example.** Clients share no cookies, sessions or headers, so examples stay independent.
2. **Never sleep to wait for something**; wait with `receive`, and move time with a fake clock (`clock:` and
   `advance`, see [Testing](../reference/api/testing.md#time)).
3. **Reset shared state** (module variables, the database, PubSub subscriptions) in `before_each`.
4. **Keep logic out of endpoints** so most specs need no request at all.

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

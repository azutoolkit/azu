# Test endpoints

Write specs for Azu endpoints with the tools Crystal and Azu already provide: an in-process `HTTP::Server`
bound to a free port, and `HTTP::Client`. The requests go through the real handler chain, the router, the
request contract and the response, exactly as in production.

Specs normally use `Azu::Testing::Client` (see [Testing](../../reference/api/testing.md)), which sends requests
through the same chain without opening a socket. The `serve` helper below, which you keep in `spec/spec_helper.cr`,
serves the app on a real port instead, which also exercises `HTTP::Server`'s socket and connection handling.

## Basic test setup

An `Azu::App` is an application as a value: it has a router and can build an `HTTP::Server`. Endpoints
declared with `get "/path"`, `post "/path"` and friends register on the default app, `Azu::App.default`.

```crystal
require "spec"
require "azu"
require "http/client"

# Serves *app* on a free local port while the block runs and yields a client for it.
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

struct HelloResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {message: "Hello, #{@name}!"}.to_json
  end
end

struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, HelloResponse)

  get "/hello/:name"

  def call : HelloResponse
    content_type "application/json"
    HelloResponse.new(params["name"])
  end
end

describe HelloEndpoint do
  it "greets by name" do
    serve do |client|
      response = client.get "/hello/Ada", headers: HTTP::Headers{"Accept" => "application/json"}

      response.status_code.should eq 200
      response.content_type.should eq "application/json"
      JSON.parse(response.body)["message"].should eq "Hello, Ada!"
      response.headers["X-Request-ID"]?.should_not be_nil
    end
  end
end
```

`RequestId` and `Rescuer` are the minimum for realistic specs: `Rescuer` turns errors raised in `call` (a
missing record, say) into the error responses clients see. A request that breaks its contract never reaches `call`;
the endpoint answers it itself. To test with the stack `Azu.start`
uses, pass `app.default_handlers` instead.

## Testing GET endpoints

Raise `Azu::Response::NotFound` for a missing resource and assert the status the client sees:

```crystal
require "spec"
require "azu"
require "http/client"

def serve(app : Azu::App = Azu::App.default, &)
  server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

USERS = {1_i64 => "Ada", 2_i64 => "Grace"}

struct UserResponse
  include Azu::Response

  def initialize(@id : Int64, @name : String)
  end

  def render
    {id: @id, name: @name}.to_json
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    id = params["id"].to_i64
    name = USERS[id]? || raise Azu::Response::NotFound.new("/users/#{id}")
    content_type "application/json"
    UserResponse.new(id, name)
  end
end

describe ShowUserEndpoint do
  json = HTTP::Headers{"Accept" => "application/json"}

  it "returns an existing user" do
    serve do |client|
      response = client.get "/users/1", headers: json

      response.status_code.should eq 200
      JSON.parse(response.body).should eq JSON.parse(%({"id": 1, "name": "Ada"}))
    end
  end

  it "answers 404 for an unknown user" do
    serve do |client|
      response = client.get "/users/99", headers: json

      response.status_code.should eq 404
    end
  end

  it "answers 404 for a path no route matches" do
    serve do |client|
      client.get("/nothing-here", headers: json).status_code.should eq 404
    end
  end
end
```

## Testing POST endpoints and validation

A request contract is enforced before `call` runs: a body that fails validation is answered with `422`
and an RFC 7807 problem document, and a body that is not valid JSON with `400`. Test both. The body is the same for every
JSON client; its `Content-Type` is `application/problem+json` only when the request's `Accept` names it, and `application/json`
otherwise (as with the `Accept: application/json` below).

```crystal
require "spec"
require "azu"
require "http/client"

def serve(app : Azu::App = Azu::App.default, &)
  server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
end

struct CreatedResponse
  include Azu::Response

  def initialize(@request : CreateUserRequest)
  end

  def render
    {name: @request.name, email: @request.email}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, CreatedResponse)

  post "/users"

  def call : CreatedResponse
    status 201
    content_type "application/json"
    CreatedResponse.new(create_user_request)
  end
end

describe CreateUserEndpoint do
  headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}

  it "creates a user from a valid body" do
    serve do |client|
      body = {name: "Ada", email: "ada@example.com"}.to_json
      response = client.post "/users", headers: headers, body: body

      response.status_code.should eq 201
      JSON.parse(response.body)["email"].should eq "ada@example.com"
    end
  end

  it "answers 422 with the validation errors" do
    serve do |client|
      response = client.post "/users", headers: headers, body: {name: "", email: "nope"}.to_json

      response.status_code.should eq 422
      response.content_type.should eq "application/json" # `application/problem+json` only if Accept names it
      JSON.parse(response.body)["status"].as_i.should eq 422
      JSON.parse(response.body)["errors"].as_h.keys.should contain "email"
    end
  end

  it "answers 400 for a body that is not JSON" do
    serve do |client|
      client.post("/users", headers: headers, body: "{not json").status_code.should eq 400
    end
  end
end
```

Request contracts can also be tested without a server, which is quicker when you only care about the
rules:

```crystal
require "spec"
require "azu"

struct SignupRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
end

describe SignupRequest do
  it "accepts valid input" do
    SignupRequest.new("Ada", "ada@example.com").valid?.should be_true
  end

  it "reports a broken field" do
    request = SignupRequest.new("Ada", "nope")

    request.valid?.should be_false
    request.errors.map(&.field).should contain :email
  end

  it "parses a JSON body like an endpoint does" do
    request = SignupRequest.from_json(%({"name": "Ada", "email": "ada@example.com"}))
    request.name.should eq "Ada"
  end
end
```

## Testing PUT, PATCH and DELETE

Verbs work the same way; `HTTP::Client` has a method for each, and an endpoint that answers
`Azu::Response::Empty` returns an empty body:

```crystal
require "spec"
require "azu"
require "http/client"

def serve(app : Azu::App = Azu::App.default, &)
  server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

NOTES = {} of Int64 => String

struct NoteResponse
  include Azu::Response

  def initialize(@id : Int64, @text : String)
  end

  def render
    {id: @id, text: @text}.to_json
  end
end

struct UpdateNoteRequest
  include Azu::Request

  getter text : String

  def initialize(@text = "")
  end

  validate text, presence: true
end

struct UpdateNoteEndpoint
  include Azu::Endpoint(UpdateNoteRequest, NoteResponse)

  put "/notes/:id"

  def call : NoteResponse
    id = params["id"].to_i64
    NOTES[id] = update_note_request.text
    content_type "application/json"
    NoteResponse.new(id, NOTES[id])
  end
end

struct DeleteNoteEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/notes/:id"

  def call : Azu::Response::Empty
    NOTES.delete(params["id"].to_i64)
    status 204
    Azu::Response::Empty.new
  end
end

describe "notes" do
  headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json"}

  before_each { NOTES.clear }

  it "updates a note" do
    serve do |client|
      response = client.put "/notes/5", headers: headers, body: {text: "remember"}.to_json

      response.status_code.should eq 200
      NOTES[5_i64].should eq "remember"
    end
  end

  it "deletes a note" do
    NOTES[5_i64] = "remember"
    serve do |client|
      response = client.delete "/notes/5", headers: headers

      response.status_code.should eq 204
      response.body.should be_empty
      NOTES.has_key?(5_i64).should be_false
    end
  end
end
```

## Testing authentication

Send the credentials the way a client does, in a header, and assert on the status:

```crystal
require "spec"
require "azu"
require "http/client"

def serve(app : Azu::App = Azu::App.default, &)
  server = app.server([Azu::Handler::Rescuer.new] of HTTP::Handler)
  address = server.bind_unused_port("127.0.0.1")
  spawn { server.listen }
  Fiber.yield
  begin
    yield HTTP::Client.new(address.address, address.port)
  ensure
    server.close
  end
end

struct SecretResponse
  include Azu::Response

  def render
    {secret: 42}.to_json
  end
end

struct SecretEndpoint
  include Azu::Endpoint(Azu::Request, SecretResponse)

  get "/secret"

  def call : SecretResponse
    raise Azu::Response::AuthenticationError.new unless header["Authorization"]? == "Bearer let-me-in"
    content_type "application/json"
    SecretResponse.new
  end
end

describe SecretEndpoint do
  it "rejects a request without a token" do
    serve do |client|
      client.get("/secret", headers: HTTP::Headers{"Accept" => "application/json"}).status_code.should eq 401
    end
  end

  it "accepts the right token" do
    serve do |client|
      headers = HTTP::Headers{"Accept" => "application/json", "Authorization" => "Bearer let-me-in"}
      client.get("/secret", headers: headers).status_code.should eq 200
    end
  end
end
```

## Testing a single app

Apps are values, so a spec can build its own instead of using the global one. Routes declared on an app
with `routes` take any `Azu::Routable`, including a plain handler:

```crystal
require "spec"
require "azu"
require "http/client"

struct Ping
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "pong"
    context
  end
end

describe "a routed handler" do
  it "answers on its path" do
    app = Azu::App.new
    app.routes { get "/ping", Ping }

    server = app.server
    address = server.bind_unused_port("127.0.0.1")
    spawn { server.listen }
    Fiber.yield

    response = HTTP::Client.get("http://127.0.0.1:#{address.port}/ping")
    response.body.should eq "pong"

    app.stop(1.second).should be_true
  end
end
```

`app.stop` stops accepting connections, sends every open WebSocket a close frame with code 1001 (going away)
and waits, up to the timeout, for the requests in flight and for those sockets to close, which is also what a
graceful shutdown does in production (see [Shut down gracefully](../deployment/graceful-shutdown.md)).

## See also

- [Testing WebSockets](test-websockets.md)
- [Testing Your App tutorial](../../tutorials/testing-your-app.md)
- [Handle validation errors](../validation/handle-validation-errors.md)

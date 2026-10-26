---
description: "Write specs for Azu endpoints with `Azu::Testing::Client`: requests, contracts, authentication, CSRF, redirects and time."
---

# Test endpoints

`require "azu/testing"` loads `Azu::Testing::Client`. The client builds each request in memory and calls the
app's handler chain and router directly, in process: no port is bound, yet the request contract, error handling
and content negotiation run as they do in production. Its full API is on [Testing](../../reference/api/testing.md).

Before you start: put `require "spec"`, `require "azu"`, `require "azu/testing"` and your application file in
`spec/spec_helper.cr`. The examples below repeat the three requires so each one runs on its own.

## Send a request

```crystal
require "spec"
require "azu"
require "azu/testing"

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
    client = Azu::Testing::Client.new.accept(:json)
    response = client.get "/hello/Ada"

    response.status_code.should eq 200
    response.content_type.should eq "application/json"
    response.json["message"].should eq "Hello, Ada!"
    response.header("X-Request-ID").should_not be_nil
  end
end
```

`Azu::Testing::Client.new` drives `Azu::App.default`, where endpoints declared with `get "/path"`, `post "/path"`
and friends register, through the handlers `RequestId` and `Rescuer`. `Rescuer` turns errors raised in `call` (a
missing record, say) into the error responses clients see; a request that breaks its contract never reaches
`call`, the endpoint answers it itself. To test with the stack `MyApp.start` uses without arguments, pass `app.default_handlers` as the
second argument. `accept(:json)` sets the `Accept` header of every request the client sends.

## Test GET endpoints

Path parameters and the query string both fill the request contract. Raise `Azu::Response::NotFound` for a
missing resource and assert what the client sees:

```crystal
require "spec"
require "azu"
require "azu/testing"

USERS = {1_i64 => "Ada", 2_i64 => "Grace"}

struct ShowUserRequest
  include Azu::Request

  getter id : Int64 = 0_i64
  getter shout : Bool = false

  def initialize(@id = 0_i64, @shout = false)
  end
end

struct UserResponse
  include Azu::Response
  include JSON::Serializable

  getter id : Int64
  getter name : String

  def initialize(@id : Int64, @name : String)
  end

  def render
    to_json
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(ShowUserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    request = show_user_request
    name = USERS[request.id]? || raise Azu::Response::NotFound.new("/users/#{request.id}")
    content_type "application/json"
    UserResponse.new(request.id, request.shout ? name.upcase : name)
  end
end

describe ShowUserEndpoint do
  it "returns an existing user" do
    response = Azu::Testing::Client.new.accept(:json).get "/users/1"

    response.status_code.should eq 200
    response.json(UserResponse).name.should eq "Ada"
  end

  it "reads query parameters" do
    client = Azu::Testing::Client.new.accept(:json)

    client.get("/users/2", params: {shout: true}).json["name"].should eq "GRACE"
  end

  it "builds the path from the endpoint's route" do
    client = Azu::Testing::Client.new.accept(:json)

    client.get(ShowUserEndpoint, id: 2).json["name"].should eq "Grace"
    client.get(ShowUserEndpoint, ShowUserRequest.new(1_i64, shout: true)).json["name"].should eq "ADA"
  end

  it "answers 404 with a problem document for an unknown user" do
    response = Azu::Testing::Client.new.accept(:json).get "/users/99"

    response.status_code.should eq 404
    response.problem?.should be_true
    response.json["title"].should eq "Not Found"
  end

  it "answers 404 for a path no route matches" do
    Azu::Testing::Client.new.accept(:json).get("/nothing-here").status_code.should eq 404
  end
end
```

`params:` appends to the query string. `client.get(ShowUserEndpoint, id: 2)` takes the path from the route the
endpoint is registered at and fills it from the named fields; `client.get(ShowUserEndpoint, request)` sends a
whole contract, and a contract of another type is a compile error. `json(UserResponse)` parses the body into any
`JSON::Serializable` type, and `json` alone returns a `JSON::Any`.

## Test POST endpoints and validation

A request contract is enforced before `call` runs: a body that fails validation is answered with `422` and a
problem document, and a body that is not valid JSON with `400`. Test both. `json:` sends a JSON body, `form:` a
form, and `body:` a raw string with the headers you pass.

```crystal
require "spec"
require "azu"
require "azu/testing"

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
  it "creates a user from a JSON body" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.post "/users", json: {name: "Ada", email: "ada@example.com"}

    response.status_code.should eq 201
    response.json["email"].should eq "ada@example.com"
  end

  it "creates a user from a form" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.post "/users", form: {"name" => "Grace", "email" => "grace@example.com"}

    response.status_code.should eq 201
  end

  it "sends the endpoint's own contract" do
    client = Azu::Testing::Client.new.accept(:json)

    client.post(CreateUserEndpoint, name: "Lin", email: "lin@example.com").status_code.should eq 201
    client.post(CreateUserEndpoint, CreateUserRequest.new("Lin", "lin@example.com")).status_code.should eq 201
  end

  it "answers 422 with the validation errors" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.post "/users", json: {name: "", email: "nope"}

    response.status_code.should eq 422
    response.problem?.should be_true
    response.content_type.should eq "application/json" # `application/problem+json` only if Accept names it
    response.json["errors"].as_h.keys.should contain "email"
  end

  it "answers 400 for a body that is not JSON" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.post "/users", body: "{not json", headers: {"Content-Type" => "application/json"}

    response.status_code.should eq 400
  end
end
```

The typed calls send a JSON body for POST, PUT and PATCH (`form: true` sends a form) and query parameters for
GET, DELETE, HEAD and OPTIONS. `problem?` is true for a problem document labelled either
`application/problem+json` or `application/json`.

Request contracts can also be tested without a request, which is quicker when you only care about the rules:

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

## Test PUT, PATCH and DELETE

The client has a method for each verb, and an endpoint that answers `Azu::Response::Empty` returns an empty
body:

```crystal
require "spec"
require "azu"
require "azu/testing"

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
  patch "/notes/:id"

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
  before_each { NOTES.clear }

  it "updates a note" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.put "/notes/5", json: {text: "remember"}

    response.status_code.should eq 200
    NOTES[5_i64].should eq "remember"
    client.patch("/notes/5", json: {text: "forget"}).json["text"].should eq "forget"
  end

  it "deletes a note" do
    NOTES[5_i64] = "remember"
    response = Azu::Testing::Client.new.delete "/notes/5"

    response.status_code.should eq 204
    response.body.should be_empty
    NOTES.has_key?(5_i64).should be_false
  end
end
```

## Test authentication

Send a token the way a client does, in a header. For a session, `login_with` logs the client in:

```crystal
require "spec"
require "azu"
require "azu/testing"

struct AccountResponse
  include Azu::Response

  def initialize(@user : String)
  end

  def render
    {user: @user}.to_json
  end
end

struct TokenAccountEndpoint
  include Azu::Endpoint(Azu::Request, AccountResponse)

  get "/api/account"

  def call : AccountResponse
    raise Azu::Response::AuthenticationError.new unless header["Authorization"]? == "Bearer let-me-in"
    content_type "application/json"
    AccountResponse.new("api")
  end
end

struct SessionAccountEndpoint
  include Azu::Endpoint(Azu::Request, AccountResponse)

  get "/account"

  def call : AccountResponse
    user = Azu.session_adapter.try(&.session(context)["user_id"]?)
    raise Azu::Response::AuthenticationError.new unless user
    content_type "application/json"
    AccountResponse.new(user)
  end
end

describe "authentication" do
  it "rejects a request without a token" do
    Azu::Testing::Client.new.accept(:json).get("/api/account").status_code.should eq 401
  end

  it "accepts the right token" do
    client = Azu::Testing::Client.new.accept(:json)
    response = client.get "/api/account", headers: {"Authorization" => "Bearer let-me-in"}

    response.status_code.should eq 200
  end

  it "reads the user from the session" do
    Azu::Testing::Client.open do |client|
      client.accept(:json).login_with { |session| session["user_id"] = "7" }

      client.get("/account").json["user"].should eq "7"
    end
  end

  it "rejects a client without a session" do
    Azu::Testing::Client.new.accept(:json).get("/account").status_code.should eq 401
  end
end
```

`login_with` installs an in-memory `Azu::SessionAdapter` on the app, starts a session in it and sends that
session's cookie with every later request of the client. Code that reads the session through
`Azu.session_adapter`, as the template helpers and the CSRF session store do, sees the values you set.
`Client.open` closes the client when the block ends, which removes the adapter again.

{% hint style="warning" %}
`login_with` raises `ArgumentError` for an app that already has a session adapter of its own. Log in through
that app's own endpoints instead, and the client keeps the cookie they set.
{% endhint %}

## Test forms, CSRF and redirects

With `Azu::Handler::CSRF` in the client's handlers, a write without a token is refused as it is in production.
`with_csrf` asks that handler for a token and sends it, with its cookie, on every POST, PUT, PATCH and DELETE:

```crystal
require "spec"
require "azu"
require "azu/testing"

struct SubscribeRequest
  include Azu::Request

  getter email : String

  def initialize(@email = "")
  end

  validate email, presence: true, match: /@/
end

struct SubscribeEndpoint
  include Azu::Endpoint(SubscribeRequest, Azu::Response::Empty)

  post "/subscriptions"

  def call : Azu::Response::Empty
    cookies HTTP::Cookie.new("subscribed", subscribe_request.email, path: "/")
    redirect to: "/thanks", status: 303
  end
end

struct ThanksResponse
  include Azu::Response

  def initialize(@email : String)
  end

  def render
    "Thanks, #{@email}"
  end
end

struct ThanksEndpoint
  include Azu::Endpoint(Azu::Request, ThanksResponse)

  get "/thanks"

  def call : ThanksResponse
    content_type "text/plain"
    ThanksResponse.new(cookies["subscribed"]?.try(&.value) || "stranger")
  end
end

def csrf_handlers : Array(HTTP::Handler)
  [Azu::Handler::RequestId.new, Azu::Handler::Rescuer.new, Azu::Handler::CSRF.new] of HTTP::Handler
end

describe SubscribeEndpoint do
  it "refuses a form without a CSRF token" do
    client = Azu::Testing::Client.new(Azu::App.default, csrf_handlers)

    client.post("/subscriptions", form: {email: "ada@example.com"}).status_code.should eq 403
  end

  it "redirects after a valid submission and keeps the cookie" do
    client = Azu::Testing::Client.new(Azu::App.default, csrf_handlers).with_csrf
    response = client.post "/subscriptions", form: {email: "ada@example.com"}

    response.status_code.should eq 303
    response.location.should eq "/thanks"
    client.cookies["subscribed"].should eq "ada@example.com"
  end

  it "follows the redirect when asked" do
    client = Azu::Testing::Client.new(Azu::App.default, csrf_handlers, follow_redirects: true).with_csrf
    response = client.post "/subscriptions", form: {email: "ada@example.com"}

    response.status_code.should eq 200
    response.body.should eq "Thanks, ada@example.com"
  end
end
```

A handler instance belongs to one chain, so `csrf_handlers` builds a fresh list for each client. A redirect is
returned as it is unless the client follows redirects; a followed 303 turns the POST into a GET. Cookies a
response sets are kept in `client.cookies` and sent back with the next request.

## Test behavior that depends on time

Give the client a fake clock and move it with `advance` instead of sleeping. The example builds its own
`Azu::App`, so its routes and handlers stay out of the other specs; `app.routes` takes any `Azu::Routable`,
including a plain handler:

```crystal
require "spec"
require "azu"
require "azu/testing"

struct Ping
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response << "pong"
  end
end

describe "the rate limit" do
  it "blocks a client for a minute after three requests" do
    app = Azu::App.new
    app.routes { get "/ping", Ping }
    throttle = Azu::Handler::Throttle.new(interval: 60, duration: 60, threshold: 3, blacklist: [] of String, whitelist: [] of String)
    client = Azu::Testing::Client.new(app, [Azu::Handler::Rescuer.new, throttle] of HTTP::Handler, clock: Azu::Clock::Fake.new)

    3.times { client.get("/ping").status_code.should eq 200 }
    blocked = client.get "/ping"
    blocked.status_code.should eq 429
    blocked.header("Retry-After").should eq "60"

    client.advance(61.seconds)
    client.get("/ping").body.should eq "pong"
  end
end
```

The client installs its clock around each of its requests, so everything that reads `Azu::Clock` during the
request (throttle windows, cache TTLs, token lifetimes) and the client's cookie jar move with `advance`. Code that
calls `Time.utc` directly does not; [Testing](../../reference/api/testing.md#time) lists what the clock covers.

## See also

- [Testing](../../reference/api/testing.md)
- [Test WebSockets](test-websockets.md)
- [Testing your app](../../tutorials/testing-your-app.md)
- [Handle validation errors](../validation/handle-validation-errors.md)

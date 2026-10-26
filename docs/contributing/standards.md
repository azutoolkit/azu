# Code standards

The conventions used in the Azu source. They are enforced by `crystal tool format`, Ameba (`.ameba.yml`) and
review; when in doubt, follow the file you are editing.

## Style

- Format with `crystal tool format`: two spaces, no tabs.
- Names: `snake_case` for methods and variables, `PascalCase` for types, `UPPER_SNAKE_CASE` for constants,
  single uppercase letters for type parameters.
- One main type per file; the file mirrors the type (`src/azu/handler/rescuer.cr` holds `Azu::Handler::Rescuer`).
  Small types that belong together may share a file. Handlers live in `src/azu/handler/`, and specs mirror the
  source tree under `spec/`.
- Public methods declare their return type. Use generics for contracts: `Azu::Endpoint(Request, Response)`.
- Prefer `struct` for value objects and endpoints, `class` for objects that hold mutable state. Use union types
  sparingly; prefer one explicit type.
- Ameba limits cyclomatic complexity to 10 per method. Split a method instead of silencing the rule.

```text
def create_user(name : String, email : String) : User   # explicit types on a public method
  User.new(name: name, email: email)
end
```

## Endpoints, requests and responses

Endpoints are structs, so every request gets its own copy. A `class` endpoint is also served on a copy per request,
which means state it keeps in its own instance variables does not carry over between requests: use a struct, and
keep shared state somewhere explicit (a cache, a database).

```crystal
struct UserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true, size: 2..50
  validate email, presence: true
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    content_type "application/json"
    UserResponse.new(user_request.name)
  end
end
```

See [Validate Requests](../how-to/validation/validate-requests.md) for the validation rules and
[Create an Endpoint](../how-to/endpoints/create-endpoint.md) for the endpoint macros.

## Handlers

A handler includes `HTTP::Handler` and calls `call_next(context)` to continue the chain. Do not keep
per-request state in instance variables: one handler instance serves all requests.

```crystal
class AuthHandler
  include HTTP::Handler

  def initialize(@token : String)
  end

  def call(context : HTTP::Server::Context)
    if context.request.headers["Authorization"]? == "Bearer #{@token}"
      call_next(context)
    else
      context.response.status = HTTP::Status::UNAUTHORIZED
      context.response.content_type = "application/json"
      context.response.print %({"error":"Unauthorized"})
    end
  end
end
```

See [Create Custom Middleware](../how-to/middleware/create-custom-middleware.md).

## Errors

Custom errors inherit from `Azu::Response::Error`, which `Azu::Handler::Rescuer` renders with the error's status.
Raise them instead of building error responses by hand.

```crystal
class OutOfStock < Azu::Response::Error
  def initialize(sku : String)
    super(title: "Out of Stock", status: HTTP::Status::CONFLICT, errors: [] of String)
    @detail = "#{sku} is out of stock"
  end
end
```

## Thread safety

- Guard shared mutable state with `Mutex#synchronize`; the cache stores and the helper registry do.
- Avoid global mutable state. `Azu::App` carries configuration and routes as values; prefer passing an app to
  reaching for `Azu::App.default`.
- Fibers share the process: a handler or endpoint that stores per-request data in an ivar races with other
  requests.

## SQL and secrets

- Bind values as parameters. Never build SQL by interpolating request input.
- Read secrets from the environment, never from source files, and do not log them.

## Documentation

- Public types and methods get a doc comment (`crystal docs` renders it).
- Markdown pages are type-checked: every file with a `crystal` block is listed in `docs/.checked` and its
  blocks must compile (see [Development Setup](setup.md#documentation)). Use `text` for output and for code
  that is not meant to compile.

## Specs

- Use Crystal's `spec`. Unit specs call a handler directly with a hand-built `HTTP::Server::Context`; integration specs bind an
  `HTTP::Server` on a free port and use `HTTP::Client`.
- A bug fix lands with a spec that fails without the fix.
- Test the failure path as well as the success path.

```crystal
require "spec"
require "azu"

class AuthHandler
  include HTTP::Handler

  def initialize(@token : String)
  end

  def call(context : HTTP::Server::Context)
    if context.request.headers["Authorization"]? == "Bearer #{@token}"
      call_next(context)
    else
      context.response.status = HTTP::Status::UNAUTHORIZED
    end
  end
end

describe AuthHandler do
  it "rejects a request without the token" do
    io = IO::Memory.new
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(io))
    handler = AuthHandler.new("secret")
    handler.next = ->(ctx : HTTP::Server::Context) { ctx.response.print "ok" }

    handler.call(context)
    context.response.close

    context.response.status.should eq HTTP::Status::UNAUTHORIZED
  end

  it "lets a request with the token through" do
    io = IO::Memory.new
    headers = HTTP::Headers{"Authorization" => "Bearer secret"}
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/", headers), HTTP::Server::Response.new(io))
    handler = AuthHandler.new("secret")
    handler.next = ->(ctx : HTTP::Server::Context) { ctx.response.print "ok" }

    handler.call(context)
    context.response.close

    io.to_s.should end_with("ok")
  end
end
```

## Pull requests

- Keep a pull request to one change, with specs and updated docs.
- `crystal spec`, `crystal tool format --check --exclude lib --exclude playground/lib` and the docs check must pass.
- Describe behaviour changes in the pull request; anything that breaks an API goes in
  [Breaking Changes](../reference/breaking-changes.md).

## Next Steps

- [Development Setup](setup.md) - Setting up your development environment
- [Roadmap](roadmap.md) - Development roadmap and priorities

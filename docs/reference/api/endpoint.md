---
description: "Endpoints handle HTTP requests with type-safe request and response contracts: route macros, the helpers of `call`, request access and redirects."
---

# Endpoint

An endpoint is a struct (or class) that includes `Azu::Endpoint(Request, Response)`: it declares its route with a
verb macro, receives the request already parsed into its request contract, and returns its response type from
`call`. It comes with `require "azu"`. It is not an `HTTP::Handler`: it is `Azu::Routable`, and the router
dispatches to it.

```crystal
struct PingResponse
  include Azu::Response

  def render
    "pong"
  end
end

struct PingEndpoint
  include Azu::Endpoint(Azu::Request, PingResponse)

  get "/ping"

  def call : PingResponse
    PingResponse.new
  end
end
```

**Type Parameters:**
- `Request` - Request contract type: a struct that includes `Azu::Request`, or the bare `Azu::Request` module for an endpoint with no contract to validate
- `Response` - Response type (must include `Azu::Response`)

## API

### HTTP method macros

`get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `connect` and `trace` register the endpoint with the
router of `Azu::App.default` when the struct is defined. A `get` route also answers `HEAD`.

```crystal
struct NoContent
  include Azu::Response

  def render
  end
end

struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request, NoContent)

  get "/users"

  def call : NoContent
    NoContent.new
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(Azu::Request, NoContent)

  post "/users"

  def call : NoContent
    NoContent.new
  end
end

struct UpdateUserEndpoint
  include Azu::Endpoint(Azu::Request, NoContent)

  put "/users/:id"

  def call : NoContent
    NoContent.new
  end
end

struct PatchUserEndpoint
  include Azu::Endpoint(Azu::Request, NoContent)

  patch "/users/:id"

  def call : NoContent
    NoContent.new
  end
end

struct DeleteUserEndpoint
  include Azu::Endpoint(Azu::Request, NoContent)

  delete "/users/:id"

  def call : NoContent
    NoContent.new
  end
end
```

{% hint style="warning" %}
Each struct declares one route: the path is remembered per type for `Endpoint.path`, so give an endpoint one verb macro.
{% endhint %}

To register an endpoint on an app of your own instead, route it explicitly (see [Router](router.md)):

```crystal
struct StatusEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.routes { get "/status", StatusEndpoint }
```

### call

The helpers below `call` are private methods of the endpoint, available inside it.

Handle the request. Must be implemented. The returned response is rendered into the HTTP response body.

```crystal
struct ShowEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/show"

  def call : Azu::Response::Empty
    # Handle request and return response
    Azu::Response::Empty.new
  end
end
```

**Returns:** the response type given to `Azu::Endpoint`

### params

Access route, query and form parameters. Looks in the route parameters first, then the query string, then the body.

```crystal
struct SearchEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id"

  def call : Azu::Response::Empty
    id = params["id"]       # raises KeyError when missing
    page = params["page"]?  # String?
    tags = params.fetch_all("tag")
    params.query            # HTTP::Params
    params.path             # Hash(String, String)
    params.form             # HTTP::Params
    params.files            # uploaded files
    params.to_h             # Hash(String, String)
    Azu::Response::Empty.new
  end
end
```

A name is looked up in the path, then the query string, then the body. What the URL addresses cannot be changed by a body
field of the same name: `POST /users/5` with `id=1` in the body gives `params["id"] == "5"`, and the typed request
(`id`) is 5. A present but empty query value (`?name=`) counts as present and wins over the body.

For a JSON body the typed request applies the same rule to the keys the body already has: a path or query
value replaces that key (compared decoded, so `"\u0069d"` is `id`; a field renamed with `@[JSON::Field(key:)]` is
replaced by the URL parameter named like the field) and keeps the JSON type the body used (a number stays a number; a
URL value that cannot take that type, such as `?price=nan`, makes the request a `400`). Numbers keep their raw text (integers beyond Int64, float notation); strings and nested values are re-serialized as equivalent JSON, and a body in which no top-level key matches is passed on untouched. Only top-level keys are replaced. When `?user_name=` and `?name=` both target a field renamed to `user_name`, the real field name wins. Keys the body does not have are **not added**: a JSON contract does not receive a path parameter its
body lacks.

{% hint style="danger" %}
So **authorize on `params["id"]` (the route), not on a field of the contract** that a body may also carry.
{% endhint %}

The CSRF handler reads its token on its own (header, form body, then query) and is not affected by this order.


**Returns:** `Azu::Params`

### header

Read the request headers, or set a response header.

```crystal
struct HeadersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/headers"

  def call : Azu::Response::Empty
    auth = header["Authorization"]?   # request header
    header "X-Custom", "value"        # response header
    Azu::Response::Empty.new
  end
end
```

**Returns:** `HTTP::Headers` (reading) or sets the header (two arguments)

### context

Access the full HTTP context.

```crystal
struct ContextEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/context"

  def call : Azu::Response::Empty
    context.request  # HTTP::Request
    context.response # HTTP::Server::Response
    Azu::Response::Empty.new
  end
end
```

**Returns:** `HTTP::Server::Context`

### method

The HTTP method of the request as an `Azu::Method`.

### cookies

Read request cookies with `cookies`, and add a cookie to the response by passing an `HTTP::Cookie`.

```crystal
struct CookieEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/cookie"

  def call : Azu::Response::Empty
    session = cookies["session"]?
    cookies HTTP::Cookie.new("seen", "1", http_only: true)
    Azu::Response::Empty.new
  end
end
```

### content_type

Set the content type of the response.

```crystal
struct TextEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/text"

  def call : Azu::Response::Empty
    content_type "text/plain"
    Azu::Response::Empty.new
  end
end
```

### status

Set the response status code.

```crystal
struct CreatedEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  post "/created"

  def call : Azu::Response::Empty
    status 201 # Created
    Azu::Response::Empty.new
  end
end
```

**Parameters:**
- `status : Int32` - HTTP status code

### error

Build an `Azu::Response::Error` for the given message and status. Return it or raise it.

```crystal
struct FailingEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/failing"

  def call : Azu::Response::Empty
    raise error("Something went wrong", 400, ["details"])
  end
end
```

### CSRF helpers

`csrf_token`, `csrf_tag` and `csrf_metatag` return the token of the current request, the hidden input
tag and the meta tag, from `Azu::Handler::CSRF.default`. They need the `Azu::Handler::CSRF` handler in the chain
(see [Built-in handlers](../handlers/built-in.md#handlercsrf)).

### Request access

The validated request is available through a method named after the request type. It is parsed once
per call, and a request that breaks its validations never reaches `call` (see [Request](request.md#request-parsing)):

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end

  validate name, presence: true
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

struct SignupEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Access request via snake_case method name
    create_user_request.email
    UserResponse.new(create_user_request.name)
  end
end
```

The method name is derived from the request type: `CreateUserRequest` becomes `create_user_request`, and
`create_user_request_contract` is an alias for it.

### redirect

Redirect to another URL. The endpoint returns `Azu::Response::Empty`.

```crystal
struct OldDashboardEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/old-dashboard"

  def call : Azu::Response::Empty
    redirect to: "/dashboard", status: 302
  end
end
```

**Parameters:**
- `to : String` - Redirect URL
- `status : Int32 = 301` - HTTP status code

### Path parameters

```crystal
struct PostEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:user_id/posts/:post_id"

  def call : Azu::Response::Empty
    user_id = params["user_id"]
    post_id = params["post_id"]
    Azu::Response::Empty.new
  end
end
```

### Wildcard parameters

```crystal
struct FilesEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/files/*path"

  def call : Azu::Response::Empty
    path = params["path"] # Captures the rest of the path
    Azu::Response::Empty.new
  end
end
```

### Endpoint.path

`Endpoint.path(**params)` returns the declared path with each argument filling the path parameter of its name, and
the prefix of the app it is mounted in: see [Template helpers](../templates/helpers.md#type-safe-endpoint-helpers).

### Declarative security, hygiene, audit, and OpenAPI macros

Class-level macros inside an `Azu::Endpoint` body configure its `Azu::RouteOptions` (inherited by subclasses and merged with `scope` and call-site options):

| Macro | Effect |
|---|---|
| `public!(flag = true)` | Marks the endpoint `public: true` so authentication and authorization are skipped |
| `require_role(*roles)` / `allow_roles(*roles)` | Requires at least `role` (or any of `roles`, or higher in `config.auth.roles`) |
| `require_permissions(*perms)` / `require_scopes(*scopes)` | Requires all listed permissions or OAuth 2.0 scopes |
| `require_any_permission(*perms)` / `require_any_scope(*scopes)` | Requires at least one of the listed permissions or scopes |
| `requires(requirement)` | Combines an `Azu::Access::Requirement` into the endpoint's requirement |
| `enrolment_exempt!(exempt = true)` | Exempts the endpoint from the enrolment gate (`principal.enrolment_pending?`) |
| `csrf_exempt!(exempt = true)` | Exempts the endpoint from `Handler::CSRF` checks |
| `audit(action = nil, *, critical = false, enabled = true)` | Configures structured audit logging for the endpoint |
| `audit!(*, critical = false)` | Enables audit logging and derives `audit_action` from the endpoint's type name (e.g. `Queues::PurgeEndpoint` -> `"queues.purge"`) |
| `no_audit!` | Disables audit logging on this endpoint (`audit: false`) |
| `summary(text)` / `description(text)` | Sets the OpenAPI operation `summary` or `description` |
| `max_body_size(bytes)` | Caps the request body size in bytes (`413 Payload Too Large` when exceeded) |
| `content_types(*types)` | Restricts accepted request `Content-Type` values (`415 Unsupported Media Type` when violated) |

### Action hooks (`before_action`, `after_action`, `around_action`)

Action hooks expand at compile time inside the endpoint with zero per-request closure allocation:

```crystal
struct AuditedActionEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  post "/audited"
  require_role :operator
  require_scopes "items:write"
  audit!

  around_action :measure_step
  before_action :verify_header
  after_action :tag_response

  private def measure_step(&) : Nil
    yield
  end

  private def verify_header : Nil
    bad_request! "Missing X-Client header", code: "missing_client" unless header["X-Client"]?
  end

  private def tag_response(_res : Azu::Response::Empty) : Nil
    header "X-Processed", "true"
  end

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end
```

### Principal, authorization, error, and halt helpers

Available as private methods inside `call` and action hooks:

| Helper | Behavior |
|---|---|
| `principal` / `principal?` / `current_user` / `current_user?` | Returns `Azu::Auth::Principal?` for the current request |
| `principal!` / `current_user!` | Returns `Azu::Auth::Principal` or raises `401` (`Response::AuthenticationError`) |
| `authenticated?` | `true` when a principal is present |
| `role?(name)` | `true` when the principal satisfies `name` (including `config.auth.roles` hierarchy) |
| `permission?(name)` / `scope?(name)` | `true` when the principal holds `name` |
| `claims` / `authly_claims` / `authly_claims!` | Verified token claims (`Hash(String, JSON::Any)`, or `Authly::Claims` when `Authly` is loaded) |
| `authorize!(requirement_or_kwargs)` | Checks `role:`, `roles:`, `permissions:`, `scopes:`, etc. against `principal!` or raises `403` |
| `unauthorized!(message, *, code, www_authenticate, details)` | Raises `401` (`Response::AuthenticationError`) |
| `forbidden!(message, *, code, details)` | Raises `403` (`Response::AuthorizationError`) |
| `not_found!(message, *, path, code, details)` | Raises `404` (`Response::NotFound`) |
| `bad_request!(message, *, code, details)` | Raises `400` (`Response::BadRequest`) |
| `conflict!(message, *, code, details)` | Raises `409` (`Response::Conflict`) |
| `unprocessable!(field, message, *, code)` | Raises `422` (`Response::ValidationError`) |
| `halt!(status = 200, body = "", headers = nil)` | Writes `status`, `headers`, and `body` immediately and short-circuits the action |

## See also

- [Authentication and authorization](auth.md)
- [Request](request.md)
- [Response](response.md)
- [Router](router.md)
- [Create an endpoint](../../how-to/endpoints/create-endpoint.md)

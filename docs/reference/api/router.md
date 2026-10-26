# Router Reference

The router handles HTTP request routing with a tree of path segments, one route per HTTP method where a path ends.

## Route Registration

### Verb macros

Routes declared with a verb macro inside an endpoint are recorded on the type (`UsersEndpoint.routes`, the
`{verb, path}` pairs in order) and registered on the router of `Azu::App.default` the first time that router is
read (`App#server`, `App#router`, `Azu.start`), so a duplicate route fails at boot. Defining the type does not touch
any router. To serve the same type from another app, register its routes there with `endpoint` (see
[Registering an endpoint type on an app](#registering-an-endpoint-type-on-an-app)):

```crystal
struct MyResponse
  include Azu::Response

  def render
    "hello"
  end
end

struct MyEndpoint
  include Azu::Endpoint(Azu::Request, MyResponse)

  get "/path" # Registers GET /path

  def call : MyResponse
    MyResponse.new
  end
end
```

### Explicit routes

An app can also declare its routes in one place with `routes`. The block yields a `Router::Builder` with the verbs
(`get`, `post`, `put`, `patch`, `delete`, `options`, `head`, `connect`, `trace`), `ws`, `scope` and `mount`. A
route points at an endpoint class or at an instance of any `Azu::Routable` (an endpoint or an `HTTP::Handler`).

```crystal
struct UsersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.routes do
  get "/users/:id", UsersEndpoint
  post "/users", UsersEndpoint

  scope "/api" do
    get "/users", UsersEndpoint # GET /api/users
  end
end

# Router#routes does the same on a router you already hold
app.router.routes("/v2") do
  get "/users", UsersEndpoint # GET /v2/users
end

# mount serves another app below a prefix
admin = Azu::App.new
admin.routes { get "/users", UsersEndpoint }
app.routes { mount admin, at: "/admin" } # GET /admin/users
```

### Registering an endpoint type on an app

`endpoint Type` inside `App#routes` (or a `scope`) registers every route the verb macros declared in `Type`, below the
builder's prefix. An endpoint type is not tied to an app: the same type can serve several, each with its own prefix,
and `Type.path` links to the route of the app serving the request.

```crystal
require "azu"

struct PingResponse
  include Azu::Response

  def render
    "pong"
  end
end

struct PingEndpoint
  include Azu::Endpoint(Azu::Request, PingResponse)

  get "/ping" # also served by Azu::App.default

  def call : PingResponse
    PingResponse.new
  end
end

api = Azu::App.new
api.routes { scope("/api") { endpoint PingEndpoint } } # GET /api/ping

admin = Azu::App.new
admin.routes { endpoint PingEndpoint } # GET /ping
```

Not per app yet: `Channel.ws` (it registers on `App.default` when the class is defined; use `ws` in `App#routes`
for another app), and the Crinja link helpers (`link_to_get_users` and friends), which are registered once per type
in a process-wide registry and link with the path of the app serving the request.

### Mounting another app

`mount` serves another app below a prefix. Requests under the prefix reach that app's router, with the prefix
removed, and run with that app's configuration. An app can be mounted once, so build one app per mount.
`Endpoint.path` includes the prefix the app is mounted at and the scope the route was declared in, so links stay
right wherever the endpoint is mounted.

## Route Patterns

A static segment matches itself, a segment that starts with `:` captures its value under that name, and a segment
that starts with `*` captures the rest of the path.

```crystal
struct UsersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.routes do
  get "/", UsersEndpoint
  get "/api/v1/health", UsersEndpoint      # Static
  get "/users/:id", UsersEndpoint          # Single parameter
  get "/posts/:id/comments", UsersEndpoint # Parameter in middle
  get "/:category/:slug", UsersEndpoint    # Multiple parameters
  get "/files/*path", UsersEndpoint        # Captures rest of path
end
```

## HTTP Methods

| Method | Macro | Description |
|--------|-------|-------------|
| GET | `get` | Retrieve resource (also answers `HEAD`) |
| POST | `post` | Create resource |
| PUT | `put` | Replace resource |
| PATCH | `patch` | Update resource |
| DELETE | `delete` | Remove resource |
| OPTIONS | `options` | Get options |
| HEAD | `head` | Get headers only |
| CONNECT | `connect` | Establish a tunnel |
| TRACE | `trace` | Loop back the request |

HTML forms can only `GET` or `POST`, so a `POST` may ask to be handled as `PUT`, `PATCH` or `DELETE` with a `_method`
field (form body or query string) or the `X-HTTP-Method-Override` header. Only `POST` is overridable and only to
those three verbs.

Trailing slashes are ignored: `/users/` matches the route `/users`.

## Route Matching

The router tries static segments before parameters, and parameters before wildcards, and falls back to the next
branch when one dead-ends. With `/users`, `/users/:id` and `/users/*rest` declared, `/users` matches the first,
`/users/123` the second and `/users/123/posts/456` the third.

A segment is a parameter only when it starts with `:` (or a wildcard with `*`, which must be the last segment): in
`/users:search` or `/files/report-:id` the colon is literal, as in the OpenAPI document. Each route keeps its own
parameter names, so `/posts/:id` and `/posts/:post_id/comments` can both be declared for one method. A parameter's
value is the raw segment, not percent-decoded.

Declaring the same method and path twice raises `Azu::Router::DuplicateRoute`, also when the paths differ only by a
trailing slash or by their parameter names (`/posts/:id` and `/posts/:slug`). A route path that does not start with
`/` raises `ArgumentError`.

## Accessing Route Parameters

Route parameters are read with `params`, next to query and form values:

```crystal
struct PostEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id/posts/:post_id"

  def call : Azu::Response::Empty
    user_id = params["id"]      # => "123"
    post_id = params["post_id"] # => "456"
    Azu::Response::Empty.new
  end
end
```

### Wildcard Parameters

```crystal
struct DocsEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/docs/*path"

  def call : Azu::Response::Empty
    path = params["path"] # => "docs/readme.md" for /docs/docs/readme.md
    Azu::Response::Empty.new
  end
end
```

## Router API

### route_info

Lists the registered routes.

```crystal
Azu::App.default.router.route_info.each do |route|
  puts "#{route["method"]} #{route["path"]} -> #{route["handler"]}"
end
```

### path_of

The path an endpoint was registered under, for building links. `nil` when the router does not route it.

```crystal
struct PathEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/path"

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

Azu::App.default.router.path_of(PathEndpoint) # => "/path"
```

### Lookup Cost

The router keeps no cache. It finds a route by walking a tree of path segments, reading the request path in place: a
static route allocates nothing, and a route with parameters allocates only their values and the params hash. A path
with more segments than any route is refused before it is read whole. `clear_path_cache` is kept for the code that
calls it and does nothing.

## Route Groups

Organize routes with common prefixes with `scope`, or declare the full path in each endpoint:

```crystal
struct ApiV1UsersIndex
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/api/v1/users"

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end
```

## Error Handling

### Not Found

When no route matches, the router answers `404` with an `Azu::Response::NotFound`, rendered as HTML, JSON, XML or
plain text according to the `Accept` header. The JSON body has the `Status`, `Title`, `Detail` and `Source` (the
path) fields.

A request is routed only when its method is one of the verbs spelled exactly (`GET`, `POST`, ...: methods are
case-sensitive) and its path starts with `/`; a WebSocket route is reached only by a `GET` upgrade. Any other request
answers `404`.

## Complete Example

```crystal
struct UsersResponse
  include Azu::Response

  def render
    "[]"
  end
end

struct UserResponse
  include Azu::Response

  def render
    "{}"
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

# User CRUD endpoints
struct UsersIndex
  include Azu::Endpoint(Azu::Request, UsersResponse)

  get "/users"

  def call : UsersResponse
    UsersResponse.new
  end
end

struct UsersShow
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    UserResponse.new
  end
end

struct UsersCreate
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    UserResponse.new
  end
end

struct UsersDelete
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    status 204
    Azu::Response::Empty.new
  end
end

# Nested routes
struct UserPosts
  include Azu::Endpoint(Azu::Request, UsersResponse)

  get "/users/:user_id/posts"

  def call : UsersResponse
    UsersResponse.new
  end
end
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Handler Reference](../handlers/built-in.md)

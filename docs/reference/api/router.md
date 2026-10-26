---
description: "`Azu::Router`: declare routes (verbs, `endpoint`, `ws`, `scope`, `mount`), how requests are matched, and what a request that matches no route gets."
---

# Router

`Azu::Router` is the segment-tree router at the end of an app's handler chain (`app.router`, the same object as
`app.config.router`). It is part of `require "azu"`. It maps the method and path of a request to an `Azu::Routable`
(an endpoint, a WebSocket channel's upgrader, a mounted app or any `HTTP::Handler`) and calls it. Routes come from an
app's `routes` block or from the verb macros in endpoint bodies. It is not middleware: the handlers passed to `start`
run before it, and it answers a request that matches no route itself.

<!-- prelude -->
```crystal
require "azu"

struct UsersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end
```

```crystal
app = Azu::App.new
app.routes do
  get "/users/:id", UsersEndpoint
  post "/users", UsersEndpoint

  scope "/api" do
    get "/users", UsersEndpoint # GET /api/users
  end
end
```

## API

### Router::Builder

`App#routes(&)` and `Router#routes(scope = "", &)` yield a `Router::Builder`; inside the block its methods are called
without a receiver. Each returns `Nil`.

| Signature | Notes |
|---|---|
| `get(path, endpoint)`, `post`, `put`, `patch`, `delete`, `options`, `head`, `connect`, `trace` | `endpoint` is an `Azu::Routable` instance, or a class the builder instantiates with `new`. `get` also registers `HEAD` and `OPTIONS` (see [HTTP methods](#http-methods)) |
| `endpoint(type)` | Registers every route the verb macros declared in `type`, below the builder's prefix. Raises `ArgumentError` ("... declares no routes") for a type that declares none |
| `ws(path, channel)` | A WebSocket route to an `Azu::Channel` class |
| `scope(prefix, &)` | Prefixes every route, mount and scope declared in the block. Scopes nest; inside one, `"/"` is the scope's own path |
| `mount(app : App, at : String)` | Serves `app` below the path (see [Mounting another app](#mounting-another-app)) |

### Router

| Signature | Returns | Notes |
|---|---|---|
| `get(path, handler : Routable)`, and the other eight verbs | — | What the builder calls, without a prefix |
| `register(verb : String, path, handler : Routable)` | — | The verb as a lowercase name (`"get"`); `ArgumentError` ("unknown HTTP verb") for another |
| `ws(path, channel : Channel.class)` | — | A WebSocket route |
| `root(endpoint : Routable)` | — | Registers `GET /` only (see [Limits](#limits)) |
| `mount(child : Configuration, at : String)` | `Nil` | What `Builder#mount` calls with the app's configuration |
| `routes(scope = "", &)` | the block's value | Yields a `Router::Builder` on this router, with `scope` as its prefix |
| `process(context)` | — | Routes one request: the method override, the lookup, `context.request.path_params`, then the route's `call`. The app calls it after the last handler |
| `path_of(endpoint : Routable.class)` | `String?` | The path the type was last registered under on this router, without the mount prefix; nil when this router does not route it |
| `mounted_as` | `Router::Mount?` | The mount this router's app is served through; nil when it is not mounted. `mount` sets it |
| `mount_prefix` | `String` | What precedes every path of this router in a URL: the mount paths of every level, `""` when not mounted |
| `route_info` | `Array(Hash(String, String))` | One hash per route, in declaration order: `"method"`, `"path"`, `"resource"` (the route key, method and path: `/get/users`), `"handler"` (the class name, or the channel's), `"description"` |
| `registered_routes` | `Array(Router::Route)` | The routes in declaration order; a `Route` has `endpoint`, `method`, `path` and `resource` |
| `clear_path_cache` | `Nil` | Does nothing: the router keeps no cache (see [Lookup cost](#lookup-cost)) |

`Router::Mount#prefix` is the full path a mount is served under, including the mounts above it, and
`Router::Mount#child` the mounted app's configuration.

### Errors

| Error | Raised when |
|---|---|
| `Azu::Router::DuplicateRoute` | A method and path is declared twice, including the `HEAD` and `OPTIONS` a `get` adds and the paths of a mount |
| `ArgumentError` | `mount` at a path that does not start with `/` or is `/`; an app mounted a second time; `endpoint` of a type without routes; `register` with an unknown verb |

## Behavior

### Verb macros

Routes declared with a verb macro inside an endpoint are recorded on the type (`MyEndpoint.routes`, the
`{verb, path}` pairs in order) and registered on the router of `Azu::App.default` the next time that router is read
(`App#router`, `App#server`, `MyApp.start`), so a duplicate route fails at boot. Defining the type does not touch
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

### Registering an endpoint type on an app

`endpoint Type` inside `App#routes` (or a `scope`) registers every route the verb macros declared in `Type`, below the
builder's prefix. An endpoint type is not tied to an app: the same type can serve several, each with its own prefix,
and `Type.path` links to the route of the app serving the request. `Azu::App.default` serves the type as well.

```crystal
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

### Scopes

`scope` prefixes what is declared inside it, and scopes nest. A trailing slash of the prefix is dropped, and `"/"`
inside a scope is the scope's own path:

```crystal
app = Azu::App.new
app.routes do
  scope "/api" do
    get "/", UsersEndpoint # GET /api
    scope "/v1" do
      get "/users", UsersEndpoint  # GET /api/v1/users
      post "/users", UsersEndpoint # POST /api/v1/users
    end
  end
end

# Router#routes does the same on a router you hold
app.router.routes("/v2") do
  get "/users", UsersEndpoint # GET /v2/users
end
```

### Mounting another app

`mount app, at: "/admin"` serves another app below a prefix:

```crystal
admin = Azu::App.new
admin.routes { get "/users", UsersEndpoint }

app = Azu::App.new
app.routes { mount admin, at: "/admin" } # GET /admin/users

app.router.route_info.first
# => {"method" => "WEBSOCKET", "path" => "/admin", "resource" => "/ws/admin",
#     "handler" => "Azu::Router::Mount", "description" => "WEBSOCKET route handler"}
```

- The mount registers one `Router::Mount` at the prefix and at `prefix/*mount_path`, for every method and for
  WebSocket upgrades: 20 routes in `route_info`, none of them the mounted app's own.
- A request under the prefix reaches the mounted app's router with the prefix removed from `request.path`
  (`/admin/users` is `/users`, `/admin` is `/`), inside `Azu.with_config(admin.config)`. The path is put back
  afterwards, also when the mounted app raises.
- A path under the prefix that the mounted app does not route gets that app's `404`, in its `error_format`, naming
  the path without the prefix.
- `Endpoint.path` and `Azu.mounted_path` add `mount_prefix`, so links stay right wherever the app is mounted.
  Mounts nest, and the prefixes add up.
- A trailing slash of the path is dropped. An app can be mounted once, because its links carry the prefix: build
  one app per mount.
- The mounted app is not started: its handlers do not run, `start` does not prepare it (templates, i18n), and
  `Azu.current_app` stays the app that owns the server. See
  [Apps, configuration and scope](../../explanation/architecture/apps-and-scope.md#what-a-mount-is).

### Route patterns

A static segment matches itself, a segment that starts with `:` captures its value under that name, and a segment
that starts with `*` captures the rest of the path.

```crystal
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

struct DocsEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/docs/*path"

  def call : Azu::Response::Empty
    path = params["path"] # => "docs/readme.md" for /docs/docs/readme.md
    Azu::Response::Empty.new
  end
end
```

### Route matching

The router tries static segments before parameters, and parameters before wildcards, and falls back to the next
branch when one dead-ends. With `/users`, `/users/:id` and `/users/*rest` declared, `/users` matches the first,
`/users/123` the second and `/users/123/posts/456` the third. Trailing slashes are ignored: `/users/` matches the route
`/users`.

A segment is a parameter only when it starts with `:` (or a wildcard with `*`, which must be the last segment): in
`/users:search` or `/files/report-:id` the colon is literal, as in the OpenAPI document. Each route keeps its own
parameter names, so `/posts/:id` and `/posts/:post_id/comments` can both be declared for one method. A parameter's
value is the raw segment, not percent-decoded.

Routes are declared before the app serves: `App#start` freezes its router, and the routers of the apps mounted in it,
before it listens. After that `add`, `root`, `ws`, `mount` and `register` (and the verb methods) raise
`Azu::Router::Frozen`, so a request never meets a router that is changing. Call `Azu::Spark.install` and the like
before `start`.

A request is routed only when its method is one of the verbs spelled exactly (`GET`, `POST`, ...: methods are
case-sensitive) and its path starts with `/`; a WebSocket route is reached only by a `GET` upgrade. Any other request
answers `404`.

### HTTP methods

| Method | Builder method and macro | Registers |
|---|---|---|
| GET | `get` | `GET`, `HEAD` and `OPTIONS`, all to the same endpoint |
| POST | `post` | `POST` |
| PUT | `put` | `PUT` |
| PATCH | `patch` | `PATCH` |
| DELETE | `delete` | `DELETE` |
| OPTIONS | `options` | `OPTIONS` |
| HEAD | `head` | `HEAD` |
| CONNECT | `connect` | `CONNECT` |
| TRACE | `trace` | `TRACE` |

A `HEAD` or `OPTIONS` request to a `get` route runs the endpoint as a `GET` does, and gets the `GET` response: the
same status, headers and body. Declaring `head` or `options` on the path of a `get` route raises `DuplicateRoute`,
in either order. A CORS preflight is answered by `Handler::CORS` before the router (see
[Built-in handlers](../handlers/built-in.md)).

HTML forms can only `GET` or `POST`, so a `POST` may ask to be handled as `PUT`, `PATCH` or `DELETE` with a `_method`
field (urlencoded form body or query string) or the `X-HTTP-Method-Override` header. Only `POST` is overridable and
only to those three verbs.

### Not found

When no route matches, the router answers `404` with an `Azu::Response::NotFound`, rendered as HTML, JSON, XML or
plain text according to the first `Accept` entry (plain text with no `Accept` or `*/*`). A JSON client gets the
problem body; this is `GET /nope` with `Accept: application/json` in production:

```json
{"type":"about:blank","title":"Not Found","status":404,"detail":"The server can't find the requested resource.","errors":[],"error_id":"e971adacb1def55a7b6661fa0433c959","instance":"/nope"}
```

`error_id` differs on every request, and development adds a `backtrace` field. The formats and statuses are listed
in [Error types](../errors/error-types.md).

### Lookup cost

The router keeps no cache. It finds a route by walking a tree of path segments, reading the request path in place: a
static route allocates nothing, and a route with parameters allocates only their values and the params hash. A path
with more segments than any route is refused before it is read whole. `clear_path_cache` is kept for the code that
calls it and does nothing.

`route_info` lists the routes, for tooling:

```crystal
Azu::App.default.router.route_info.each do |route|
  puts "#{route["method"]} #{route["path"]} -> #{route["handler"]}"
end
```

## Limits

- **`HEAD` responses carry the body.** The endpoint behind a `get` route writes its body for a `HEAD` request too,
  and it is sent. An HTTP/1.1 client that reuses the connection reads those bytes as the start of the next response.
- **`OPTIONS` runs the `GET` endpoint.** There is no `Allow` header and no `405`: a method a path does not route
  answers `404`.
- **`root`.** `Router#root` registers `GET /` only (no `HEAD`, no `OPTIONS`), and `path_of` does not know it. A
  `get "/"` declared after it, or `root` after a `get "/"`, raises `DuplicateRoute`.
  Use `get "/", Endpoint` instead.
- **Not per app:** a class-level `Channel.ws "/path"` registers on `Azu::App.default` when the class is defined (use
  `ws` in `App#routes` for another app), and the template link helpers (`link_to_get_users` and friends) are
  registered once per type in a process-wide registry and link with the path of the app serving the request.

## See also

- [App](app.md)
- [Endpoint](endpoint.md)
- [Built-in handlers](../handlers/built-in.md)
- [Mount an app under a prefix](../../how-to/apps/mount-an-app.md)

# Endpoint

Endpoints handle HTTP requests with type-safe request and response contracts.

## Including Endpoint

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

An endpoint is a plain struct (or class). It is not an `HTTP::Handler`: it is `Azu::Routable`, and the router dispatches to it.

## HTTP Method Macros

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

Each struct declares one route: the path is remembered per type for `Endpoint.path`, so give an endpoint one verb macro.

To register an endpoint on an app of your own instead, route it explicitly (see [Router Reference](router.md)):

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

## Instance Methods

The helpers below are private methods of the endpoint, available inside `call`.

### call

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
body lacks. So **authorize on `params["id"]` (the route), not on a field of the contract** that a body may also carry.
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
tag and the meta tag. They need the `Azu::Handler::CSRF` handler in the chain.

## Request Access

The validated request is available through a method named after the request type. It is parsed once
per call, and a request that breaks its validations never reaches `call` (see [Request Reference](request.md)):

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

## Redirects

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

## Route Parameters

### Path Parameters

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

### Wildcard Parameters

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

## Complete Example

```crystal
struct User
  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email)
  end

  def self.find?(id : Int64) : User?
    new(id, "Ada", "ada@example.com") if id == 1
  end
end

struct ShowUserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id:    @user.id,
      name:  @user.name,
      email: @user.email,
    }.to_json
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, ShowUserResponse)

  get "/users/:id"

  def call : ShowUserResponse
    user_id = params["id"].to_i64
    user = User.find?(user_id) || raise Azu::Response::NotFound.new("/users/#{user_id}")

    content_type "application/json"
    ShowUserResponse.new(user)
  end
end
```

## See Also

- [Request Reference](request.md)
- [Response Reference](response.md)
- [Router Reference](router.md)

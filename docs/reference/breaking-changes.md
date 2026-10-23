# Breaking Changes

This document lists breaking changes between Azu versions and migration guides.

## Version 0.5.x

### Unreleased (0.6 work)

**Requiring `azu` no longer starts anything.** Before, `require "azu"` set the root `Log` level to `Debug`
with Azu's formatter, created the upload temp directory and started seven background fibers.

- Logging: neither `require "azu"` nor `start` configures `Log` any more, so an app that sets up `Log`
  itself keeps its backend and level. To get the previous Azu format at `Debug`, call
  `Azu.setup_logging` once at boot (before `start`).
- The async log pipeline starts on the first log entry or reported error, or in `start`.
- The upload temp directory and its cleanup task are created by `start` (or by the first upload for
  apps that never call `start`).
- The profiler and memory monitor that development mode turns on by default now start in `start`
  instead of when the configuration is built.

**Routes can belong to an app** (additive; the endpoint macros keep registering on `Azu::App.default`).

<!-- skip -->
```crystal
app = Azu::App.new
app.routes do
  get "/users/:id", UserEndpoint
  scope "/api" do
    post "/users", CreateUserEndpoint
  end
  mount admin_app, at: "/admin"
end
```

- `scope` really prefixes now (`Router::Builder` used to ignore its scope).
- `mount` serves another app below a prefix with that app's own router and configuration. An app can be
  mounted once; build one app per mount.
- `Endpoint.path` includes the prefix the app is mounted at and the scope the route was declared in,
  so links stay right wherever the endpoint is mounted. A link to an endpoint another app routes is
  returned without any prefix.
- `Router#routes { }` now yields `Router::Builder`, which declares verbs, `ws`, `scope` and `mount`; it no
  longer forwards other calls (`root`, `add`) to the router.

**Request contracts are enforced.** An endpoint whose request type has validations no longer runs when the
request breaks them: the router answers `422` before `call`, and the parsed request is built once per call.

- The body is RFC 7807 `application/problem+json`:
  `{"type": "about:blank", "title": "Validation Error", "status": 422, "detail": "...", "errors": {"name": ["must be present"]}}`.
- To keep the pre-0.6 body (`FieldErrors`, `ErrorId`, ...) for one more minor release, set
  `config.error_format = Azu::ErrorFormat::Legacy`.
- Endpoints declared with the bare `Azu::Request` module have no contract and are not affected.

### 0.5.28

**No breaking changes.** This version includes documentation improvements.

### 0.5.0

**Endpoint Type Parameters**

The `Endpoint` module now requires explicit type parameters:

```crystal
# Before (0.4.x)
struct MyEndpoint
  include Azu::Endpoint

  def call
    # ...
  end
end

# After (0.5.x)
struct MyEndpoint
  include Azu::Endpoint(MyRequest, MyResponse)

  def call : MyResponse
    # ...
  end
end
```

**Migration:**
1. Add request type as first parameter (use `EmptyRequest` for no body)
2. Add response type as second parameter
3. Add return type annotation to `call`

**Request Access**

Request objects are now accessed via generated methods:

```crystal
# Before
request.name

# After
my_request.name  # Method name derived from request type
create_user_request.name  # For CreateUserRequest
```

## Version 0.4.x

### 0.4.0

**Handler Interface**

Handlers now use `call_next` instead of `next.try &.call`:

```crystal
# Before (0.3.x)
def call(context)
  # ...
  next.try &.call(context)
end

# After (0.4.x)
def call(context)
  # ...
  call_next(context)
end
```

**Configuration**

Configuration moved from class methods to block syntax:

```crystal
# Before (0.3.x)
Azu.port = 8080
Azu.env = :production

# After (0.4.x)
Azu.configure do |config|
  config.port = 8080
  config.env = Environment::Production
end
```

## Version 0.3.x

### 0.3.0

**Router Changes**

Route registration moved to macros:

```crystal
# Before (0.2.x)
Azu.router.add("GET", "/users", UsersEndpoint)

# After (0.3.x)
struct UsersEndpoint
  include Azu::Endpoint

  get "/users"  # Route defined with macro

  def call
    # ...
  end
end
```

**Response Objects**

Responses now implement `Azu::Response` module:

```crystal
# Before (0.2.x)
def call
  {users: users}.to_json
end

# After (0.3.x)
struct UsersResponse
  include Azu::Response

  def render
    {users: @users}.to_json
  end
end
```

## Version 0.2.x

### 0.2.0

**WebSocket Channels**

Channel API changed from callback-based to method-based:

```crystal
# Before (0.1.x)
Azu.channel("/chat") do |socket, message|
  # Handle message
end

# After (0.2.x)
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_message(message)
    # Handle message
  end
end
```

## Deprecation Notices

### Deprecated in 0.5.x

- `Azu::Handler::Base#next` - Use `call_next(context)` instead
- Implicit request types - Always specify request type parameter

### Removed in 0.5.x

- `Azu::Endpoint` without type parameters
- `Azu.start` without handler array

## Migration Tools

### Checking for Deprecations

Run the compiler in strict mode:

```bash
crystal build --warnings=all src/app.cr
```

### Version Compatibility

| Azu Version | Crystal Version |
|-------------|-----------------|
| 0.5.x | 1.19.1 and newer (CI runs 1.19.1 and the latest release) |
| 0.4.x | 0.35.0 - 1.0.0 |
| 0.3.x | 0.35.0 - 0.36.x |

## Getting Help

If you encounter issues during migration:

1. Check the [GitHub Issues](https://github.com/azutopia/azu/issues)
2. Review the [CHANGELOG](https://github.com/azutopia/azu/blob/master/CHANGELOG.md)
3. Ask in the [Crystal Forum](https://forum.crystal-lang.org/)

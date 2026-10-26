---
description: Common questions, issues, and solutions when working with Azu.
---

# FAQ and troubleshooting

## Frequently asked questions

### General questions

<details>

<summary>What makes Azu different from other web frameworks?</summary>

Azu emphasizes compile-time type safety and contract-first development. Endpoints, contracts and responses are typed, so a type error in them shows up when you build, not in production. Input is still checked per request: before `call` runs, the endpoint parses the request into its contract and runs the contract's `validate` rules, and answers `400` or `422` when the request breaks it.

</details>

<details>

<summary>Can I use Azu for production applications?</summary>

Azu is built to be deployed: it has a default handler stack with error pages and security headers, graceful shutdown, environment-based configuration and a health check handler. See [Deploy to Production](tutorials/deploying-to-production.md).

</details>

<details>

<summary>How does Azu compare to other Crystal web frameworks?</summary>

Azu focuses on type-safe contracts and real-time features, while frameworks like Kemal prioritize simplicity. Azu provides more structure and compile-time guarantees at the cost of some flexibility.

</details>

<details>

<summary>Do I need to learn Crystal to use Azu?</summary>

Yes, basic Crystal knowledge is required. However, Crystal's syntax is similar to Ruby, making it approachable for developers from many backgrounds.

</details>

### Technical questions

<details>

<summary>How do I handle database connections in Azu?</summary>

Azu works with CQL (Crystal Query Language), which provides typed models and queries. Define the schema once,
point models at it, and use them in endpoints:

```crystal
require "azu"
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./app.db") do
  table :users do
    primary :id, Int64
    column :name, String
    column :email, String
    timestamps
  end
end

class User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String
  property email : String
  property created_at : Time?
  property updated_at : Time?

  def initialize(@name : String, @email : String)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {id: @user.id, name: @user.name}.to_json
  end
end

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    content_type "application/json"
    user = User.find?(params["id"].to_i64)
    raise Azu::Response::NotFound.new(context.request.path) unless user
    UserResponse.new(user)
  end
end
```

See the [Database documentation](reference/database/cql-api.md) for the CQL API.

</details>

<details>

<summary>Can I use Azu with existing Crystal libraries?</summary>

Yes. Azu is a regular shard on top of `HTTP::Server`, so any Crystal library can be used in your endpoints and
handlers.

</details>

<details>

<summary>How do I handle authentication?</summary>

Implement it as a handler that runs before the router, and reject unauthenticated requests there:

```crystal
class AuthenticationHandler
  include HTTP::Handler

  def initialize(@token : String)
  end

  def call(context : HTTP::Server::Context)
    unless context.request.headers["Authorization"]? == "Bearer #{@token}"
      context.response.status = HTTP::Status::UNAUTHORIZED
      context.response.print "Authentication required"
      return
    end

    call_next(context)
  end
end

module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  AuthenticationHandler.new(ENV["API_TOKEN"]),
] of HTTP::Handler
```

An array passed to `start` replaces the default handler stack, so list the handlers you still want. See
[Create Custom Middleware](how-to/middleware/create-custom-middleware.md).

</details>

<details>

<summary>How do I deploy Azu applications?</summary>

Compile your application and deploy the binary, or a Docker image built from it:

```bash
crystal build --release --no-debug src/my_app.cr
```

See [Deploy to Production](tutorials/deploying-to-production.md) and
[Deploy with Docker](how-to/deployment/deploy-with-docker.md).

</details>

## Common issues

### Compilation issues

<details>

<summary>"can't infer type" errors</summary>

Crystal infers most types, but the endpoint macros need the request and response types spelled out:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end

  validate name, presence: true
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    @name
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    UserResponse.new(create_user_request.name)
  end
end
```

</details>

<details>

<summary>Template not found</summary>

```text
Error: Missing template: users/show.jinja
```

**Solution:** the template path is relative to the working directory the server runs in, and its default is not
your project's `templates` directory. Set it explicitly (or set `TEMPLATES_PATH`, a comma separated list):

```crystal
module MyApp
  include Azu

  configure do |config|
    config.templates.path = "./public/templates"
    config.template_hot_reload = config.env.development?
  end
end
```

`templates.path=` adds a directory to the search path. See [Render HTML Templates](how-to/templates/render-html-templates.md).

</details>

### Runtime issues

<details>

<summary>WebSocket connections not working</summary>

**Symptoms:**

- WebSocket connection fails
- No error messages in logs
- Client can't connect

**Solutions:**

1. Check that the channel is registered and the path matches the client URL. A channel implements all six
   callbacks, otherwise it does not compile:

```crystal
class MyChannel < Azu::Channel
  ws "/websocket"

  def on_connect
  end

  def on_message(message : String)
    send message
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
```

2. Check the allowed origins. A browser sends an `Origin` header with the upgrade request, and the channel checks
   it against `config.websocket.allowed_origins`:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.websocket.allowed_origins = ["http://localhost:3000"]
  end
end
```

3. Check the client connection:

```javascript
// Make sure the URL matches the server route
const ws = new WebSocket("ws://localhost:4000/websocket");
```

</details>

<details>

<summary>Request validation not working</summary>

**Symptoms:**

- Validation rules ignored
- Invalid data passes through

**Solutions:**

1. Validation runs before `call` for any endpoint whose request type declares `validate` rules, and the endpoint answers
   `422` itself (a body it cannot parse answers `400`), with or without `Rescuer` in the stack. Endpoints declared with
   the bare `Azu::Request` module have no contract and are not validated.

2. Check the rule syntax:

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
```

See [Validate Requests](how-to/validation/validate-requests.md).

</details>

<details>

<summary>File uploads not working</summary>

**Symptoms:**

- File uploads fail with `413` or `400`
- Uploaded files are empty
- `params.files` has no entry

**Solutions:**

1. Raise the limit if the file is over the default 10 MB (`UPLOAD_MAX_FILE_SIZE` sets the same, in bytes):

```crystal
module MyApp
  include Azu

  configure do |config|
    config.upload.max_file_size = 50_u64 * 1024 * 1024
    config.upload.temp_dir = "/tmp/uploads"
  end
end
```

2. The form must be `multipart/form-data`, and uploaded files are read from `params.files`, not from the
   request contract:

```crystal
struct UploadEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  post "/upload"

  def call : Azu::Response::Empty
    upload = params.files["file"]?
    raise error("File is required") unless upload

    begin
      File.copy(upload.temp_path, "/var/uploads/#{Random::Secure.hex(8)}")
    ensure
      upload.cleanup
    end
    Azu::Response::Empty.new
  end
end
```

See [Handle File Uploads](how-to/file-handling/handle-file-uploads.md).

</details>

### Performance issues

<details>

<summary>Slow response times</summary>

**Diagnosis:**

1. Check the request log. `Azu::Handler::Logger` prints the status and latency of every request and is part of the
   default stack. If you pass your own array to `start`, include it.

2. Check for work that holds up a request: a slow query, a call to another service without a timeout. Fibers
   do not run in parallel on one thread, so a long CPU-bound loop in an endpoint delays every other request on
   that thread.

See [Optimize Endpoints](how-to/performance/optimize-endpoints.md) and
[Optimize Database Queries](how-to/performance/optimize-database-queries.md).

</details>

<details>

<summary>Memory leaks</summary>

**Common causes:**

- Not cleaning up uploaded files (temp files older than `config.upload.max_temp_age` are removed by a background
  task, but remove them as soon as you are done)
- Keeping references to WebSocket connections in a global collection
- Unbounded caches or hashes

**Solutions:**

1. Clean up resources with `ensure`:

```crystal
def save(upload : Azu::Params::Multipart::File, destination : String) : Nil
  File.copy(upload.temp_path, destination)
ensure
  upload.cleanup
end
```

2. Do not keep sockets yourself: broadcast through [`Azu::PubSub`](how-to/real-time/broadcast-messages.md), which
   drops a channel when its connection closes.

</details>

### Development issues

<details>

<summary>Hot reload not working</summary>

Template hot reload is on in the development, test and pipeline environments and off elsewhere. Set it explicitly
(or set `TEMPLATE_HOT_RELOAD=true`):

```crystal
module MyApp
  include Azu

  configure do |config|
    config.template_hot_reload = true
  end
end
```

It watches the files in the configured template directories, so check that `templates.path` points at the
directory you are editing. See [Enable Hot Reload](how-to/templates/enable-hot-reload.md).

</details>

<details>

<summary>CORS issues in development</summary>

**Symptoms:**

- Browser blocks requests from frontend
- CORS errors in console

**Solution:** add the `CORS` handler with your frontend origin. By default no origin is allowed:

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::CORS.new(
    origins: ["http://localhost:3000"],
    methods: %w(GET POST PUT PATCH DELETE OPTIONS),
    headers: %w(Accept Content-Type Authorization)
  ),
] of HTTP::Handler
```

</details>

## Debugging tips

### Enable debug logging

Requiring `azu` does not configure `Log`. Call `Azu.setup_logging` once at boot to get Azu's format at `Debug`
level:

```crystal
Azu.setup_logging
Log.for("my_app").debug { "visible" }
```

### Inspect request data

```crystal
struct InspectEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/inspect"

  def call : Azu::Response::Empty
    log = Log.for("inspect")
    log.debug { "Params: #{params.to_h}" }
    log.debug { "Headers: #{header}" }
    Azu::Response::Empty.new
  end
end
```

### Test individual components

A request contract can be built from a parameter string, the same way the router builds it:

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

request = CreateUserRequest.from_www_form("name=test&email=test@example.com")
puts request.valid?
puts request.name
```

## Performance troubleshooting

### Profile your application

For a running development server, `require "azu/dev"` adds the profiler and dashboard (see
[Monitor performance](how-to/performance/monitor-performance.md)).

## Getting help

### Community resources

- **GitHub Issues**: [azutoolkit/azu/issues](https://github.com/azutoolkit/azu/issues)
- **Crystal Community**: [Crystal Language Forum](https://forum.crystal-lang.org/)
- **Documentation**: [Official Azu Docs](https://azutopia.gitbook.io/azu/)

### Reporting issues

When reporting issues, include:

1. **Crystal version**: `crystal --version`
2. **Azu version**: the `version` in the shard's `shard.lock`
3. **Minimal reproduction case**
4. **Error messages and stack traces**
5. **Environment details** (OS, deployment method)

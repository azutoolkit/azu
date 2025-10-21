# Core API

The core API provides the fundamental building blocks for Azu applications, including endpoints, requests, responses, and the main application class.

## Azu::Application

The main application class that orchestrates your Azu web application.

### Methods

#### `start(middleware : Array(Azu::Handler::Base) = [] of Azu::Handler::Base)`

Starts the Azu application with the specified middleware stack.

```crystal
# Start with default middleware
Azu.start

# Start with custom middleware
Azu.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  Azu::Handler::Static.new
]
```

#### `stop`

Gracefully stops the application.

```crystal
Azu.stop
```

## Azu::Endpoint

Base class for all HTTP endpoints in Azu.

### Methods

#### `get(path : String)`

#### `post(path : String)`

#### `put(path : String)`

#### `patch(path : String)`

#### `delete(path : String)`

Define HTTP routes for the endpoint.

```crystal
struct UserEndpoint
  include Azu::Endpoint

  get "/users/:id"
  post "/users"
  put "/users/:id"
  delete "/users/:id"

  def call
    # Implementation
  end
end
```

#### `call`

The main method that handles the HTTP request. Must be implemented by each endpoint.

```crystal
def call
  # Your endpoint logic here
end
```

## Azu::Request

Represents an HTTP request with type-safe parameter access.

### Properties

- `params` - Hash of route parameters
- `query` - Hash of query parameters
- `body` - Request body content
- `headers` - HTTP headers
- `method` - HTTP method
- `path` - Request path

### Request Methods

#### `param(key : String) : String`

Get a route parameter by key.

```crystal
def call
  user_id = request.param("id")
  # user_id is guaranteed to be a String
end
```

#### `query(key : String) : String?`

Get a query parameter by key.

```crystal
def call
  page = request.query("page") || "1"
end
```

#### `header(key : String) : String?`

Get an HTTP header by key.

```crystal
def call
  content_type = request.header("Content-Type")
end
```

## Azu::Response

Base class for all HTTP responses in Azu.

### Response Methods

#### `status(code : Int32)`

Set the HTTP status code.

```crystal
def call
  response.status(201)
  # ... rest of response
end
```

#### `header(key : String, value : String)`

Set an HTTP header.

```crystal
def call
  response.header("Content-Type", "application/json")
  # ... rest of response
end
```

#### `body(content : String)`

Set the response body.

```crystal
def call
  response.body("Hello, World!")
end
```

## Azu::Router

Handles HTTP routing in Azu applications.

### Router Methods

#### `add_route(method : String, path : String, handler : Azu::Endpoint)`

Add a route to the router.

```crystal
router.add_route("GET", "/users/:id", UserEndpoint.new)
```

#### `route(method : String, path : String) : Azu::Endpoint?`

Find a route handler for the given method and path.

```crystal
handler = router.route("GET", "/users/123")
```

## Azu::Component

Base class for real-time components in Azu.

### Component Methods

#### `content`

Generate the component's HTML content.

```crystal
def content
  # Return HTML string
end
```

#### `on_event(name : String, data : Hash(String, String))`

Handle client-side events.

```crystal
def on_event(name, data)
  case name
  when "click"
    # Handle click event
  end
end
```

## Azu::Channel

Base class for WebSocket channels in Azu.

### Channel Methods

#### `on_connect`

Called when a client connects to the channel.

```crystal
def on_connect
  # Connection logic
end
```

#### `on_message(message : String)`

Called when a message is received from the client.

```crystal
def on_message(message)
  # Handle incoming message
end
```

#### `on_disconnect`

Called when a client disconnects from the channel.

```crystal
def on_disconnect
  # Cleanup logic
end
```

## Azu::Configuration

Configuration management for Azu applications.

### Configuration Properties

- `port` - Server port (default: 3000)
- `host` - Server host (default: "0.0.0.0")
- `environment` - Application environment
- `debug` - Debug mode flag

### Configuration Methods

#### `configure(&block)`

Configure the application.

```crystal
Azu.configure do |config|
  config.port = 8080
  config.host = "localhost"
  config.debug = true
end
```

## Azu::Environment

Environment detection and configuration.

### Environment Methods

#### `development? : Bool`

Check if running in development mode.

```crystal
if Azu::Environment.development?
  # Development-specific logic
end
```

#### `production? : Bool`

Check if running in production mode.

```crystal
if Azu::Environment.production?
  # Production-specific logic
end
```

## Azu::Cache

Caching system for Azu applications.

### Cache Methods

#### `get(key : String) : String?`

Get a value from the cache.

```crystal
value = Azu::Cache.get("user:123")
```

#### `set(key : String, value : String, ttl : Time::Span? = nil)`

Set a value in the cache.

```crystal
Azu::Cache.set("user:123", "John Doe", 1.hour)
```

#### `delete(key : String)`

Delete a value from the cache.

```crystal
Azu::Cache.delete("user:123")
```

## Azu::Templates

Template rendering system for Azu applications.

### Template Methods

#### `render(template : String, context : Hash(String, String) = {} of String => String) : String`

Render a template with the given context.

```crystal
html = Azu::Templates.render("user.html", {"name" => "John"})
```

#### `register_template(name : String, content : String)`

Register a template.

```crystal
Azu::Templates.register_template("user.html", "<h1>{{ name }}</h1>")
```

## Error Handling

Azu provides comprehensive error handling through the `Azu::Response::Error` class.

### Azu::Response::Error

Base class for all Azu errors.

```crystal
class CustomError < Azu::Response::Error
  def initialize(message : String)
    super(message, 400)
  end
end
```

### Error Response

Error responses automatically set appropriate HTTP status codes and provide error details.

```crystal
def call
  raise CustomError.new("Invalid input")
rescue CustomError => e
  response.status(e.status_code)
  response.body(e.message)
end
```

## Performance Monitoring

Azu includes built-in performance monitoring for components and endpoints.

### Component Performance

Components automatically track rendering time and memory usage.

```crystal
class UserComponent < Azu::Component
  def content
    # Component content
  end
end
```

### Endpoint Performance

Endpoints can be monitored for response times and resource usage.

```crystal
struct UserEndpoint
  include Azu::Endpoint

  def call
    # Endpoint logic
  end
end
```

## Next Steps

- Learn about [Request Validation](validation.md)
- Explore [Template Rendering](templates.md)
- Understand [WebSocket Channels](websockets.md)
- See [Component System](components.md)

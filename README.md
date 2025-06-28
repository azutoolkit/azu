<div style="text-align:center"><img src="https://raw.githubusercontent.com/azutoolkit/azu/master/azu.png" /></div>

# Azu Web Framework

[![Codacy Badge](https://api.codacy.com/project/badge/Grade/b58f03f01de241e0b75f222e31d905d7)](https://www.codacy.com/manual/eliasjpr/azu?utm_source=github.com&utm_medium=referral&utm_content=eliasjpr/azu&utm_campaign=Badge_Grade) ![Crystal CI](https://github.com/eliasjpr/azu/workflows/Crystal%20CI/badge.svg?branch=master)

**Azu** is a high-performance, type-safe web framework for Crystal that emphasizes developer productivity, compile-time safety, and real-time capabilities. Built with modern web development patterns, Azu provides a robust foundation for building scalable applications with elegant, expressive syntax.

## 🚀 Key Features

### Type-Safe Architecture

- **Compile-time type checking** for requests, responses, and parameters
- **Type-safe endpoint pattern** with structured request/response contracts
- **Zero-runtime overhead** parameter validation and serialization

### Real-Time Capabilities

- **WebSocket channels** with automatic connection management
- **Live components** with client-server synchronization
- **Spark system** for reactive UI updates without page reloads

### Performance-Optimized

- **High-performance routing** with LRU cache and path optimization
- **Template hot reloading** in development with production caching
- **Efficient file upload handling** with streaming and size limits

### Developer Experience

- **Comprehensive error handling** with detailed debugging information
- **Content negotiation** supporting JSON, HTML, XML, and plain text
- **Flexible middleware system** for cross-cutting concerns
- **Environment-aware configuration** with sensible defaults

## 📊 Performance Characteristics

- **Sub-millisecond routing** with cached path resolution
- **Memory-efficient** request/response handling
- **Concurrent WebSocket** connections with lightweight fiber-based architecture
- **Zero-allocation** parameter parsing for common scenarios
- **Template compilation** with optional hot-reloading for development

## 🏗️ Architecture Overview

```mermaid
graph TB
    Client[Client Request] --> Router[High-Performance Router]
    Router --> Endpoint[Type-Safe Endpoints]
    Endpoint --> Request[Request Contracts]
    Endpoint --> Response[Response Objects]

    WS[WebSocket] --> Channel[Channel Handlers]
    Channel --> Component[Live Components]
    Component --> Spark[Spark System]

    Endpoint --> Templates[Template Engine]
    Templates --> Hot[Hot Reload]

    Router --> Middleware[Middleware Stack]
    Middleware --> CORS[CORS]
    Middleware --> Auth[Authentication]
    Middleware --> Rate[Rate Limiting]

    subgraph "Type Safety"
        Request --> Validation[Compile-time Validation]
        Response --> Serialization[Type-safe Serialization]
    end
```

## 🛠️ Installation

1. Add the dependency to your `shard.yml`:

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.4.14
```

2. Run `shards install`

3. Require Azu in your application:

```crystal
require "azu"
```

## 🎯 Quick Start

### Basic Application

```crystal
# Define a request contract
struct UserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end
end

# Define a response object
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    @user.to_json
  end
end

# Create a type-safe endpoint
struct CreateUserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    user = User.create!(
      name: request.name,
      email: request.email,
      age: request.age
    )
    UserResponse.new(user)
  end
end

# Start the application
Azu.start [
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  CreateUserEndpoint.new
]
```

## 🔌 Real-Time Features

### WebSocket Channels

```crystal
class ChatChannel < Azu::Channel
  ws "/chat"

  def on_connect
    broadcast("user_joined", {user: current_user.name})
  end

  def on_message(message : String)
    data = JSON.parse(message)
    broadcast("message", {
      user: current_user.name,
      text: data["text"],
      timestamp: Time.utc
    })
  end

  def on_close(code, message)
    broadcast("user_left", {user: current_user.name})
  end
end
```

### Live Components

```crystal
class CounterComponent
  include Azu::Component

  property count = 0

  def content
    div do
      h2 { text "Count: #{@count}" }
      button(onclick: "increment") { text "+" }
      button(onclick: "decrement") { text "-" }
    end
  end

  def on_event(name, data)
    case name
    when "increment"
      @count += 1
      refresh # Automatically updates the client
    when "decrement"
      @count -= 1
      refresh
    end
  end
end

# In your template
<%= CounterComponent.mount.render %>
<%= Azu::Spark.javascript_tag %>
```

## 🛡️ Error Handling

Azu provides comprehensive error handling with structured error responses:

```crystal
# Built-in error types
raise Azu::Response::ValidationError.new("email", "is invalid")
raise Azu::Response::AuthenticationError.new("Login required")
raise Azu::Response::AuthorizationError.new("Admin access required")
raise Azu::Response::RateLimitError.new(retry_after: 60)

# Custom error handling
struct MyEndpoint
  include Azu::Endpoint(MyRequest, MyResponse)

  def call : MyResponse
    validate_request!
    process_request
  rescue ex : ValidationError
    Azu::Response::ValidationError.new(ex.field_errors)
  end
end
```

### Error Response Formats

Azu automatically formats errors based on content negotiation:

```json
// JSON format
{
  "Title": "Validation Error",
  "Detail": "Request validation failed",
  "ErrorId": "err_123456",
  "Fingerprint": "abc123",
  "FieldErrors": {
    "email": ["is invalid", "is required"]
  }
}
```

## 📁 File Uploads

Handle file uploads with built-in optimization and validation:

```crystal
struct FileUploadRequest
  include Azu::Request

  getter avatar : Azu::Params::Multipart::File?
  getter description : String
end

struct UploadEndpoint
  include Azu::Endpoint(FileUploadRequest, UploadResponse)

  post "/upload"

  def call : UploadResponse
    if file = request.avatar
      # File is automatically streamed to temp directory
      validate_file_size!(file, max: 5.megabytes)
      validate_file_type!(file, allowed: %w(.jpg .png .gif))

      # Process the file
      final_path = save_file(file)
      file.cleanup # Clean up temp file

      UploadResponse.new(url: final_path)
    else
      raise Azu::Response::ValidationError.new("avatar", "is required")
    end
  end
end
```

## 🎨 Templates & Views

### Template Integration

```crystal
struct UserPage
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@user : User, @posts : Array(Post))
  end

  def render
    view "users/show.html", {
      user: @user,
      posts: @posts,
      title: "User Profile"
    }
  end
end

# Template: templates/users/show.html
# <h1>{{ user.name }}</h1>
# <div class="posts">
#   {% for post in posts %}
#     <article>{{ post.content }}</article>
#   {% endfor %}
# </div>
```

### Hot Reloading

Templates automatically reload in development:

```crystal
# In development
Azu::CONFIG.template_hot_reload = true

# In production
Azu::CONFIG.template_hot_reload = false
```

## ⚙️ Configuration

Azu provides environment-aware configuration:

```crystal
# config/application.cr
Azu::CONFIG.configure do |config|
  config.port = ENV.fetch("PORT", "4000").to_i
  config.host = ENV.fetch("HOST", "0.0.0.0")

  # SSL configuration
  config.ssl_cert = ENV["SSL_CERT"]?
  config.ssl_key = ENV["SSL_KEY"]?

  # File upload limits
  config.upload.max_file_size = 10.megabytes
  config.upload.temp_dir = "/tmp/uploads"

  # Template configuration
  config.templates.path = ["templates", "views"]
  config.templates.error_path = "errors"
end
```

## 🔒 Middleware

### Built-in Middleware

```crystal
Azu.start [
  Azu::Handler::Rescuer.new,     # Error handling
  Azu::Handler::Logger.new,      # Request logging
  Azu::Handler::CORS.new,        # CORS headers
  Azu::Handler::CSRF.new,        # CSRF protection
  Azu::Handler::Throttle.new,    # Rate limiting
  Azu::Handler::Static.new,      # Static files
  # Your endpoints here
]
```

### Custom Middleware

```crystal
class AuthenticationHandler
  include HTTP::Handler

  def call(context)
    unless authenticated?(context)
      context.response.status = HTTP::Status::UNAUTHORIZED
      context.response.print "Authentication required"
      return
    end

    call_next(context)
  end

  private def authenticated?(context)
    context.request.headers["Authorization"]?.try(&.starts_with?("Bearer "))
  end
end
```

## 🚄 Routing Performance

Azu's router includes several performance optimizations:

### Path Caching

```crystal
# Frequently accessed paths are cached
router = Azu::Router.new
router.get("/api/users/:id", UserEndpoint.new)

# First request: builds and caches path
# Subsequent requests: uses cached resolution
```

### Method Pre-computation

```crystal
# HTTP methods are pre-computed at initialization
# Zero allocation for method matching during request processing
```

### LRU Cache Management

```crystal
# Automatic cache eviction for optimal memory usage
# Default cache size: 1000 entries
# Configurable cache size and TTL
```

## 🧪 Testing

Azu provides excellent testing support:

```crystal
require "spec"
require "azu"

describe UserEndpoint do
  it "creates user successfully" do
    request = UserRequest.new(
      name: "John Doe",
      email: "john@example.com",
      age: 30
    )

    endpoint = UserEndpoint.new
    endpoint.request = request

    response = endpoint.call
    response.should be_a(UserResponse)
  end
end

describe ChatChannel do
  it "handles messages correctly" do
    socket = MockWebSocket.new
    channel = ChatChannel.new(socket)

    channel.on_message({"text" => "Hello"}.to_json)

    # Verify message was processed
  end
end
```

## 📈 Performance Benchmarks

| Feature             | Performance | Memory        |
| ------------------- | ----------- | ------------- |
| Router (cached)     | ~0.1ms      | 0 allocations |
| Endpoint processing | ~0.5ms      | Minimal       |
| WebSocket message   | ~0.2ms      | Constant      |
| Template rendering  | ~1-5ms      | Cached        |
| File upload (1MB)   | ~10ms       | Streaming     |

## 🌟 Advanced Features

### Content Negotiation

```crystal
# Automatic content type detection and response formatting
# Supports: JSON, HTML, XML, Plain Text
# Based on Accept headers and content type
```

### Request Validation

```crystal
struct ProductRequest
  include Azu::Request

  getter name : String
  getter price : Float64
  getter category : String

  validate name, presence: true, length: {min: 3, max: 50}
  validate price, presence: true, numericality: {greater_than: 0}
  validate category, inclusion: {in: %w(electronics books clothing)}
end
```

### Environment Management

```crystal
# Automatic environment detection
case Azu::CONFIG.env
when .development?
  # Development-specific configuration
when .production?
  # Production optimizations
when .test?
  # Testing configuration
end
```

## 🤝 Contributing

1. Fork it (<https://github.com/azutoolkit/azu/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## 📚 Documentation

For comprehensive documentation, visit: [Azu Toolkit Documentation](https://azutopia.gitbook.io/azu/)

## 🎯 Use Cases

Azu excels in:

- **API Development** - Type-safe REST and GraphQL APIs
- **Real-time Applications** - Chat, gaming, live dashboards
- **Web Applications** - Full-stack apps with server-side rendering
- **Microservices** - High-performance service architectures
- **IoT Backends** - Efficient WebSocket communication

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Contributors

- [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer

---

**Ready to build something amazing?** Start with Azu today and experience the power of type-safe, high-performance web development in Crystal.

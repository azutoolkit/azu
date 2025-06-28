# API Reference

Complete reference for Azu's core modules, classes, and configuration options.

## Core Modules

### Azu

The main module that includes the application framework.

```crystal
module Azu
  CONFIG = Configuration.new

  # Include this module in your application
  macro included
    def self.configure(&)
      with CONFIG yield CONFIG
    end

    def self.start(handlers : Array(HTTP::Handler))
      # Start the server with middleware stack
    end
  end
end
```

**Methods:**

- `configure(&block)` - Configure the application
- `start(handlers)` - Start the server with middleware
- `log` - Access the application logger
- `env` - Get current environment
- `config` - Access configuration object

### Azu::Request

Module for creating type-safe request contracts.

```crystal
module Azu::Request
  # Automatic includes when using this module
  include JSON::Serializable
  include URI::Params::Serializable
  include Schema::Validation

  # Class methods
  def self.from_json(payload : String)
  def self.from_www_form(params : String)
  def self.from_query(query_string : String)

  # Instance methods
  def valid? : Bool
  def validate! : Bool | ValidationError
  def errors : Array(Schema::ValidationError)
  def error_messages : Array(String)
  def to_json : String
  def to_www_form : String
end
```

**Validation Methods:**

- `validate(field, **rules)` - Add validation rules
- `valid?` - Check if request is valid
- `errors` - Get validation errors

### Azu::Response

Base module for response objects.

```crystal
module Azu::Response
  abstract def render

  # Error classes
  class Error < Exception
    property status : HTTP::Status
    property title : String
    property detail : String
    property errors : Array(String)
    property context : ErrorContext?
    property error_id : String
    property fingerprint : String

    def json : String
    def html : String
    def xml : String
    def text : String
  end

  class ValidationError < Error
    getter field_errors : Hash(String, Array(String))
  end

  class AuthenticationError < Error
  end

  class AuthorizationError < Error
  end

  class RateLimitError < Error
    getter retry_after : Int32?
  end
end
```

### Azu::Endpoint(Request, Response)

Module for creating type-safe endpoints.

```crystal
module Azu::Endpoint(Request, Response)
  include HTTP::Handler

  abstract def call : Response

  # HTTP method macros
  macro get(path)
  macro post(path)
  macro put(path)
  macro patch(path)
  macro delete(path)
  macro head(path)
  macro options(path)

  # Helper methods
  def params : Params
  def context : HTTP::Server::Context
  def method : Method
  def header : HTTP::Headers
  def cookies : HTTP::Cookies
  def json : JSON::Any

  # Response helpers
  def status(code : Int32)
  def content_type(type : String)
  def header(key : String, value : String)
  def cookie(cookie : HTTP::Cookie)
  def redirect(location : String, status = 301)
  def error(message : String, status = 400, errors = [] of String)
end
```

### Azu::Channel

Base class for WebSocket channels.

```crystal
abstract class Azu::Channel
  # WebSocket lifecycle methods
  abstract def on_connect
  abstract def on_message(message : String)
  abstract def on_close(code, message)

  # Optional lifecycle methods
  def on_binary(binary : Bytes)
  def on_ping(message : String)
  def on_pong(message : String)

  # Route definition
  macro ws(path)

  # Helper methods
  def socket : HTTP::WebSocket
  def params : Hash(String, String)
  def send_message(data)
  def close_connection
  def broadcast(message, exclude = nil)
end
```

### Azu::Component

Module for live components.

```crystal
module Azu::Component
  # Required methods
  abstract def content

  # Event handling
  def on_event(name : String, data)

  # Lifecycle hooks
  def on_mount
  def on_unmount
  def on_update

  # Component methods
  def refresh
  def mount(id : String? = nil)
  def unmount
  def send_event(name : String, data = {})

  # Rendering helpers
  def render : String
  def to_html : String
end
```

## Handler Classes

### Azu::Handler::Logger

Request logging middleware.

```crystal
class Azu::Handler::Logger
  include HTTP::Handler

  def initialize(@log : Log = Azu::CONFIG.log)
  end

  def call(context)
    start_time = Time.monotonic
    call_next(context)
    duration = Time.monotonic - start_time

    @log.info do
      "#{context.request.method} #{context.request.path} " \
      "#{context.response.status_code} #{duration.total_milliseconds}ms"
    end
  end
end
```

### Azu::Handler::CORS

Cross-Origin Resource Sharing middleware.

```crystal
class Azu::Handler::CORS
  include HTTP::Handler

  def initialize(
    @allowed_origins = ["*"],
    @allowed_methods = %w(GET POST PUT PATCH DELETE OPTIONS),
    @allowed_headers = %w(Accept Content-Type Authorization),
    @max_age = 86400
  )
  end

  def call(context)
    set_cors_headers(context)

    if context.request.method == "OPTIONS"
      context.response.status = HTTP::Status::NO_CONTENT
      return
    end

    call_next(context)
  end
end
```

### Azu::Handler::Rescuer

Error handling and exception catching middleware.

```crystal
class Azu::Handler::Rescuer
  include HTTP::Handler

  def call(context)
    call_next(context)
  rescue ex : Azu::Response::Error
    ex.to_s(context)
  rescue ex : Exception
    error = Azu::Response::Error.from_exception(ex, 500)
    error.to_s(context)
  end
end
```

### Azu::Handler::Static

Static file serving middleware.

```crystal
class Azu::Handler::Static
  include HTTP::Handler

  def initialize(
    @public_dir = "public",
    @fallthrough = true,
    @dir_listing = false
  )
  end

  def call(context)
    if context.request.method == "GET" || context.request.method == "HEAD"
      serve_static_file(context)
    else
      call_next(context)
    end
  end
end
```

### Azu::Handler::RequestId

Request ID tracking middleware.

```crystal
class Azu::Handler::RequestId
  include HTTP::Handler

  def initialize(@header_name = "X-Request-ID")
  end

  def call(context)
    request_id = context.request.headers[@header_name]? || generate_id
    context.request.headers[@header_name] = request_id
    context.response.headers[@header_name] = request_id

    call_next(context)
  end

  private def generate_id : String
    Random::Secure.hex(16)
  end
end
```

### Azu::Handler::Throttle

Rate limiting middleware.

```crystal
class Azu::Handler::Throttle
  include HTTP::Handler

  def initialize(
    @limit = 100,
    @window = 1.hour,
    @key_generator : Proc(HTTP::Server::Context, String) = ->(ctx : HTTP::Server::Context) {
      ctx.request.remote_address.to_s
    }
  )
  end

  def call(context)
    key = @key_generator.call(context)

    if rate_limited?(key)
      context.response.status = HTTP::Status::TOO_MANY_REQUESTS
      context.response.headers["Retry-After"] = @window.total_seconds.to_i.to_s
      context.response.print "Rate limit exceeded"
      return
    end

    record_request(key)
    call_next(context)
  end
end
```

## Configuration

### Azu::Configuration

Main configuration class.

```crystal
class Azu::Configuration
  # Server configuration
  property host : String = "0.0.0.0"
  property port : Int32 = 4000
  property port_reuse : Bool = false

  # SSL configuration
  property ssl_cert : String?
  property ssl_key : String?
  property tls : OpenSSL::SSL::Context::Server?

  # Template configuration
  property templates : Templates
  property template_hot_reload : Bool = false

  # Upload configuration
  property upload : UploadConfig

  # Environment
  property env : Environment

  # Logging
  property log : Log

  # Router
  property router : Router

  def tls? : Bool
    !@ssl_cert.nil? && !@ssl_key.nil?
  end
end
```

### Template Configuration

```crystal
class Azu::Templates
  property path : Array(String) = ["templates"]
  property error_path : String = "errors"
  property crinja : Crinja::Environment

  def load(template_name : String) : Crinja::Template
  def render(template_name : String, data) : String
end
```

### Upload Configuration

```crystal
struct Azu::UploadConfig
  property max_file_size : Int64 = 10.megabytes
  property temp_dir : String = "/tmp/uploads"
  property allowed_extensions : Array(String) = [] of String
  property allowed_mime_types : Array(String) = [] of String
end
```

## Utility Classes

### Azu::Router

High-performance routing system.

```crystal
class Azu::Router
  RESOURCES = %w(get post put patch delete head options)

  def initialize
    @radix_tree = Radix::Tree(HTTP::Handler).new
    @route_cache = LRUCache(String, Route).new(1000)
  end

  def get(path, handler)
  def post(path, handler)
  def put(path, handler)
  def patch(path, handler)
  def delete(path, handler)
  def head(path, handler)
  def options(path, handler)

  def find(path : String, method : String) : Route?
  def process(context : HTTP::Server::Context)
end
```

### Azu::Params

Parameter handling and parsing.

```crystal
class Azu::Params(T)
  def initialize(@request : HTTP::Request)
  end

  def [](key : String) : String
  def []?(key : String) : String?
  def to_query : String
  def to_hash : Hash(String, String)
  def json : String?
  def multipart : Hash(String, Multipart::File)?

  struct Multipart::File
    getter filename : String?
    getter content_type : String?
    getter body : IO
    getter size : Int64

    def save(path : String)
    def cleanup
  end
end
```

### Azu::Environment

Environment detection and configuration.

```crystal
enum Azu::Environment
  Development
  Test
  Production

  def development?
  def test?
  def production?

  def self.current : Environment
  def self.set(env : String | Environment)
end
```

---

**Next Steps:**

- **[Performance →](performance.md)** - Performance tuning and optimization
- **[Testing →](testing.md)** - Testing your Azu applications
- **[Migration →](migration.md)** - Upgrading and compatibility information

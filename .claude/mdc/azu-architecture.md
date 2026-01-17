# Azu Framework Architecture MDC

> **Domain:** Framework Architecture & Component Design
> **Applies to:** Core framework modules in `src/azu/`

## Architectural Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    HTTP Server (Crystal)                     │
├─────────────────────────────────────────────────────────────┤
│                     Middleware Chain                         │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐           │
│  │RequestId│→│ Logger  │→│  CORS   │→│  CSRF   │→ ...      │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘           │
├─────────────────────────────────────────────────────────────┤
│                      Router (Radix Tree)                     │
│              Path Caching │ Method Dispatch                  │
├───────────────┬─────────────────────────┬───────────────────┤
│   Endpoints   │       Channels          │    Components     │
│  HTTP/REST    │     WebSockets          │   Real-time UI    │
├───────────────┴─────────────────────────┴───────────────────┤
│                    Request/Response Contracts                │
│              Validation │ Serialization │ Errors            │
├─────────────────────────────────────────────────────────────┤
│                     Support Services                         │
│        Cache │ Templates │ Params │ Configuration           │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Router (`router.cr`)

The router uses a Radix tree for O(k) route matching where k is path length.

**Key Features:**
- Thread-safe path caching (max 1000 entries, LRU eviction)
- Method-aware routing with pre-computed method cache
- WebSocket upgrade detection
- Builder pattern for scoped routes

**Implementation Pattern:**
```crystal
class Router
  @radix : Radix::Tree(Proc(HTTP::Server::Context, Nil))
  @cache : Hash(String, Radix::Result) = {} of String => Radix::Result
  @cache_mutex = Mutex.new

  def match(method : String, path : String) : Radix::Result?
    cache_key = "#{method}:#{path}"

    @cache_mutex.synchronize do
      if cached = @cache[cache_key]?
        return cached
      end

      result = @radix.find(path)
      @cache[cache_key] = result if result && @cache.size < 1000
      result
    end
  end
end
```

### 2. Endpoint System (`endpoint.cr`)

Endpoints are the primary request handlers, combining routing and type safety.

**Pattern:**
```crystal
module Endpoint(Request, Response)
  macro included
    # Generate HTTP method macros
    {% for method in [:get, :post, :put, :patch, :delete] %}
      macro {{method.id}}(path)
        CONFIG.router.{{method.id}}(\{{path}}, self.new)
      end
    {% end %}

    # Generate request accessor
    def request : Request
      @_request ||= Request.from_params(params)
    end
  end

  abstract def call : Response
end
```

**Lifecycle:**
1. Router matches path to endpoint
2. Endpoint instantiated
3. Request object parsed from params
4. Validation executed
5. `call` method invoked
6. Response rendered

### 3. Request Contracts (`request.cr`)

Requests define the expected input structure with validation.

**Integration with Schema shard:**
```crystal
module Request
  macro included
    include JSON::Serializable
    include URI::Params::Serializable
    include Schema

    # Auto-generate validation methods
    def valid? : Bool
      schema_valid?
    end

    def errors : Array(Schema::Error)
      schema_errors
    end
  end
end
```

### 4. Response Objects (`response.cr`)

Responses encapsulate output with content negotiation.

**Error Response Hierarchy:**
```
Response::Error (base)
├── ValidationError (422)
├── AuthenticationError (401)
├── AuthorizationError (403)
├── RateLimitError (429)
├── DatabaseError (500)
├── ExternalServiceError (502)
└── TimeoutError (408)
```

**Content Negotiation:**
```crystal
def to_s(context : HTTP::Server::Context) : String
  case context.request.headers["Accept"]?
  when /json/
    to_json
  when /xml/
    to_xml
  when /html/
    to_html
  else
    to_text
  end
end
```

### 5. Middleware Chain (`handler/`)

Middleware follows the Chain of Responsibility pattern.

**Handler Interface:**
```crystal
abstract class Handler
  include HTTP::Handler

  property next : HTTP::Handler?

  def call(context : HTTP::Server::Context)
    # Pre-processing
    before(context)

    # Pass to next handler
    call_next(context)

    # Post-processing
    after(context)
  rescue ex
    handle_error(context, ex)
  end

  def before(context); end
  def after(context); end
end
```

**Standard Handler Order:**
1. RequestId - Assign tracking ID
2. PerformanceMonitor - Start timing (optional)
3. Rescuer - Catch exceptions
4. Logger - Log request/response
5. CORS - Handle cross-origin
6. CSRF - Validate tokens
7. Throttle - Rate limiting
8. Static - Serve static files
9. Router - Dispatch to endpoints

### 6. WebSocket Channels (`channel.cr`)

Channels handle WebSocket connections with lifecycle hooks.

**Implementation:**
```crystal
abstract class Channel
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    if websocket_upgrade?(context)
      handle_websocket(context)
    else
      call_next(context)
    end
  end

  abstract def on_connect(socket : HTTP::WebSocket)
  abstract def on_message(socket : HTTP::WebSocket, message : String)
  abstract def on_close(socket : HTTP::WebSocket)
end
```

### 7. Spark System (`spark.cr`)

Real-time component synchronization for live UI updates.

**Architecture:**
```
Server                          Client
┌──────────────┐                ┌──────────────┐
│  Component   │ ──WebSocket──► │   Preact     │
│  Registry    │ ◄──Events──── │  Hydration   │
│  (Pooled)    │                │              │
└──────────────┘                └──────────────┘
```

**Event Binding:**
- `live-click` - Click events
- `live-change` - Form changes
- `live-input` - Input events

**Component Lifecycle:**
```crystal
class Component
  def mount(socket : HTTP::WebSocket)
    # Called when component connects
  end

  def unmount
    # Called when component disconnects
  end

  def on_event(event : String, payload : JSON::Any)
    # Handle client events
  end

  def refresh
    # Push updated HTML to client
  end
end
```

### 8. Caching System (`cache.cr`)

Multi-store caching with consistent interface.

**Store Hierarchy:**
```
CacheStore (interface)
├── MemoryStore
│   └── LRU eviction, TTL support
├── RedisStore
│   └── Connection pooling, atomic ops
└── NullStore
    └── No-op for disabled caching
```

**Usage Pattern:**
```crystal
# Fetch with lazy computation
user = cache.fetch("user:#{id}", ttl: 5.minutes) do
  User.find(id)
end

# Atomic counter
cache.increment("requests:#{path}")
```

## Configuration System

**Environment-Based Configuration:**
```crystal
Azu.configure do |config|
  # Server
  config.port = ENV.fetch("PORT", "4000").to_i
  config.host = ENV.fetch("HOST", "0.0.0.0")

  # Environment
  config.env = Environment.parse(ENV.fetch("AZU_ENV", "development"))

  # Features
  config.template_hot_reload = config.env.development?
  config.performance_enabled = ENV.has_key?("PERFORMANCE_MONITORING")

  # Cache
  config.cache_config.store = ENV.fetch("CACHE_STORE", "memory")
  config.cache_config.redis_url = ENV["REDIS_URL"]?
end
```

## Extension Points

### Adding Custom Middleware
```crystal
class CustomHandler < Azu::Handler::Base
  def call(context : HTTP::Server::Context)
    # Custom logic
    call_next(context)
  end
end

# Register in pipeline
Azu.configure do |config|
  config.handlers.insert(3, CustomHandler.new)
end
```

### Adding Custom Response Types
```crystal
class PDFResponse
  include Azu::Response

  def initialize(@pdf_data : Bytes); end

  def render : String
    @pdf_data.to_s
  end

  def content_type : String
    "application/pdf"
  end
end
```

### Adding Custom Cache Store
```crystal
class MemcachedStore
  include Azu::CacheStore

  def get(key : String) : String?
    @client.get(key)
  end

  def set(key : String, value : String, ttl : Time::Span? = nil)
    @client.set(key, value, exptime: ttl.try(&.total_seconds.to_i) || 0)
  end
end
```

## Performance Optimization

### Compile-Time Feature Flags
```crystal
{% if env("PERFORMANCE_MONITORING") == "true" %}
  require "./performance_metrics"
  PERF_ENABLED = true
{% else %}
  PERF_ENABLED = false
{% end %}
```

### Component Pooling
- Max 50 components per type in pool
- Reduces allocation overhead
- Garbage collection sweep every 10 seconds

### Path Caching
- 1000 entry limit with LRU eviction
- Thread-safe access via Mutex
- Bypasses Radix tree for cached routes

# Performance Design

This document explains the performance-oriented design decisions in Azu and how they contribute to high throughput and low latency.

## Design Principles

Azu's performance design follows these principles:

1. **Zero-cost abstractions** - High-level code compiles to efficient machine code
2. **Minimal allocations** - Reduce garbage collection pressure
3. **Cache-friendly** - Optimize for CPU cache hits
4. **Async I/O** - Never block on I/O operations

## Crystal's Performance Foundation

Azu benefits from Crystal's performance characteristics:

### LLVM Compilation

```
Crystal Source → Crystal Compiler → LLVM IR → Machine Code
                                        ↓
                              Optimized native binary
```

Crystal compiles to LLVM IR, benefiting from decades of optimization work.

### Stack Allocation

Value types (structs) are stack-allocated:

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end
end
```

`UserResponse` instances:
- Allocated on stack when possible
- No GC overhead for short-lived objects
- Cache-friendly memory layout

### No Runtime Reflection

Types are resolved at compile time:
- No runtime type checking overhead
- Method calls are direct, not looked up
- Generics compile to specialized code

## Router Performance

The router uses a radix tree for O(k) route matching:

### Radix Tree Structure

```
            /
           users
          /     \
        GET    :id
         |    /    \
      Index GET  DELETE
```

Characteristics:
- Path lookup is O(k) where k = path length
- Shared prefixes stored once
- No regex matching for static segments

### Path Caching

Frequently accessed paths are cached:

```crystal
# Router maintains LRU cache
PathCache = LRUCache(String, RouteMatch).new(1000)

def find(method, path)
  key = "#{method}:#{path}"

  if cached = PathCache.get(key)
    return cached
  end

  match = tree.find(path)
  PathCache.set(key, match)
  match
end
```

## Request Processing

### Minimal Parsing

Request bodies are parsed lazily:

```crystal
# Body not parsed until accessed
def call
  # If you never access the request body,
  # it's never parsed
  headers["Accept"]  # Just header access, no body parsing
end
```

### Streaming Bodies

Large bodies can be streamed:

```crystal
def call
  # Stream without loading entire body
  request.body.each_chunk do |chunk|
    process(chunk)
  end
end
```

## Handler Pipeline

### Direct Dispatch

Handlers use direct method calls, not dynamic dispatch:

```crystal
# Compile-time known handler chain
handlers = [Rescuer.new, Logger.new, MyEndpoint.new]

# At runtime: direct calls
handlers[0].call(context)
  → handlers[1].call(context)
    → handlers[2].call(context)
```

### No Middleware Allocation

Handler instances are created once at startup:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,  # Created once
  Azu::Handler::Logger.new,   # Reused for all requests
  MyEndpoint.new,
]
```

## Response Generation

### Pre-computed Headers

Common headers are pre-computed:

```crystal
CONTENT_TYPE_JSON = "application/json"
CONTENT_TYPE_HTML = "text/html; charset=utf-8"

# No string allocation per request
response.headers["Content-Type"] = CONTENT_TYPE_JSON
```

### Efficient JSON Serialization

Crystal's JSON serialization is compile-time generated:

```crystal
struct User
  include JSON::Serializable

  property id : Int64
  property name : String
end

# Compiles to direct field access, no reflection
user.to_json  # Efficient serialization
```

## Template Caching

Templates are compiled and cached:

```crystal
# Development: optional hot-reload
# Production: compiled once, cached forever

if config.template_hot_reload
  template = compile_template(path)
else
  template = TemplateCache.fetch(path) { compile_template(path) }
end
```

## Component Pooling

Frequently used components are pooled:

```crystal
class ComponentPool
  MAX_SIZE = 50

  @pool = [] of Component

  def acquire : Component
    @pool.pop? || Component.new
  end

  def release(component : Component)
    if @pool.size < MAX_SIZE
      component.reset
      @pool << component
    end
  end
end
```

Benefits:
- Reduced allocation overhead
- Faster component instantiation
- Bounded memory usage

## Fiber-Based Concurrency

Crystal uses fibers for lightweight concurrency:

```crystal
# Each request runs in a fiber
# Thousands of fibers can run concurrently

spawn do
  handle_request(request)
end
```

Fiber characteristics:
- ~8KB stack (vs ~1MB for threads)
- No OS thread overhead
- Cooperative scheduling

## I/O Optimization

### Non-Blocking I/O

All I/O operations are non-blocking:

```crystal
# This doesn't block the thread
response = HTTP::Client.get(url)

# While waiting, other fibers run
```

### Connection Pooling

Database and HTTP connections are pooled:

```crystal
# Database connections reused
AcmeDB = CQL::Schema.define(..., pool_size: 20)

# HTTP clients maintain connection pools
HTTP::Client.new(host, pool: true)
```

## Benchmarks

Typical performance characteristics:

| Metric | Value |
|--------|-------|
| Requests/sec | 100k+ (simple endpoint) |
| Latency (p50) | <1ms |
| Latency (p99) | <5ms |
| Memory per request | <1KB |

## Profiling

Use Crystal's profiling tools:

```bash
# CPU profiling
crystal build --release src/app.cr
perf record -g ./app
perf report

# Memory profiling
crystal build --release -D gc_stats src/app.cr
./app  # Prints GC statistics
```

## Best Practices

1. **Use structs for value objects**
   ```crystal
   struct Point  # Stack allocated
     property x : Int32
     property y : Int32
   end
   ```

2. **Avoid string concatenation in loops**
   ```crystal
   # Bad
   result = ""
   items.each { |i| result += i.to_s }

   # Good
   result = String.build do |io|
     items.each { |i| io << i }
   end
   ```

3. **Cache computed values**
   ```crystal
   def expensive_computation
     @cached_result ||= compute_value
   end
   ```

4. **Use batch operations**
   ```crystal
   # Instead of individual inserts
   users.each { |u| u.save }

   # Use bulk insert
   User.insert_all(users)
   ```

## See Also

- [Architecture Overview](overview.md)
- [How to Optimize Endpoints](../../how-to/performance/optimize-endpoints.md)
- [How to Optimize Database Queries](../../how-to/performance/optimize-database-queries.md)

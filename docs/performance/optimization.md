# Optimization Strategies

Comprehensive guide to optimizing Azu applications for maximum performance and efficiency.

## Overview

Azu provides multiple layers of optimization opportunities, from compile-time optimizations to runtime performance tuning. This guide covers strategies for achieving optimal performance in production environments.

## Compile-Time Optimizations

### Type Safety Benefits

```crystal
# Compile-time optimizations through type safety
struct OptimizedEndpoint
  include Endpoint(OptimizedRequest, OptimizedResponse)

  get "/optimized/:id"

  def call : OptimizedResponse
    # Crystal's type system eliminates runtime checks
    id = @request.params["id"].to_i32

    # Compile-time method resolution
    user = User.find(id)

    # Zero-cost abstractions
    OptimizedResponse.new(user)
  end
end
```

**Benefits:**

- **Method dispatch**: Resolved at compile time
- **Memory layout**: Optimized for type safety
- **Null checks**: Eliminated where possible

### Macro Optimizations

```crystal
# Macro-based optimizations
macro optimized_routes
  {% for method, path in ROUTES %}
    {{method.id}} "{{path}}"
  {% end %}
end

# Compile-time route generation
struct OptimizedRouter
  include Router

  optimized_routes
end
```

## Memory Management

### Object Pooling

```crystal
# Object pooling for high-frequency operations
class ConnectionPool
  @pool = [] of Database::Connection
  @mutex = Mutex.new

  def get_connection : Database::Connection
    @mutex.synchronize do
      if @pool.empty?
        create_new_connection
      else
        @pool.pop
      end
    end
  end

  def return_connection(connection)
    @mutex.synchronize do
      @pool << connection
    end
  end
end
```

### Memory-Efficient Data Structures

```crystal
# Use appropriate data structures
struct MemoryOptimizedEndpoint
  include Endpoint(MemoryRequest, MemoryResponse)

  def call : MemoryResponse
    # Use Array instead of Set for small collections
    small_collection = Array(String).new(10)

    # Use String.build for string concatenation
    result = String.build do |str|
      str << "prefix"
      str << @request.data
      str << "suffix"
    end

    MemoryResponse.new(result)
  end
end
```

## Database Optimization

### Query Optimization

```crystal
# Optimized database queries
struct DatabaseOptimizedEndpoint
  include Endpoint(DbRequest, DbResponse)

  def call : DbResponse
    # Use eager loading to avoid N+1 queries
    users = User.includes(:posts, :comments)
                .where(active: true)
                .limit(100)

    # Use select to fetch only needed columns
    user_data = users.select(:id, :name, :email)

    DbResponse.new(user_data)
  end
end
```

### Connection Pooling

```crystal
# Database connection pooling
CONFIG.database = {
  pool_size: 20,
  pool_timeout: 5.seconds,
  checkout_timeout: 5.seconds,
  max_retries: 3
}

# Connection pool configuration
class DatabasePool
  @pool = DB::Pool.new(
    DB::Connection.new(CONFIG.database_url),
    initial_pool_size: CONFIG.database.pool_size,
    max_pool_size: CONFIG.database.pool_size * 2
  )
end
```

## Caching Strategies

### Response Caching

```crystal
# Response caching with TTL
struct CachedEndpoint
  include Endpoint(CacheRequest, CacheResponse)

  def call : CacheResponse
    cache_key = generate_cache_key(@request)

    if cached_response = cache.get(cache_key)
      return CacheResponse.from_cache(cached_response)
    end

    # Generate fresh response
    response = generate_response(@request)

    # Cache for 5 minutes
    cache.set(cache_key, response, ttl: 5.minutes)

    CacheResponse.new(response)
  end
end
```

### Fragment Caching

```crystal
# Template fragment caching
class FragmentCache
  @cache = {} of String => String

  def cached_fragment(key, ttl = 1.hour)
    if cached = @cache[key]?
      return cached
    end

    # Generate fragment
    fragment = yield

    # Cache fragment
    @cache[key] = fragment

    fragment
  end
end
```

## Async Processing

### Background Jobs

```crystal
# Background job processing
struct AsyncEndpoint
  include Endpoint(AsyncRequest, AsyncResponse)

  def call : AsyncResponse
    # Spawn background job
    spawn do
      process_heavy_task(@request.data)
    end

    # Return immediately
    AsyncResponse.new(job_id: generate_job_id)
  end
end
```

### WebSocket Optimization

```crystal
# Optimized WebSocket handling
class OptimizedChannel < Azu::Channel
  ws "/optimized"

  def on_message(message)
    # Use spawn for non-blocking operations
    spawn do
      result = process_message_async(message)
      broadcast(result)
    end
  end

  def on_connect
    # Minimal connection setup
    subscribe_to_channel("optimized")
  end
end
```

## Template Optimization

### Compile-Time Template Compilation

```crystal
# Pre-compiled templates
class OptimizedTemplate
  include Templates::Renderable

  # Templates compiled at build time
  COMPILED_TEMPLATES = {
    "user_list" => compile_template("user_list.html"),
    "user_detail" => compile_template("user_detail.html")
  }

  def render(template_name, data)
    COMPILED_TEMPLATES[template_name].render(data)
  end
end
```

### Template Caching

```crystal
# Template caching strategy
class TemplateCache
  @cache = {} of String => CompiledTemplate

  def get_or_compile(template_path)
    @cache[template_path] ||= compile_template(template_path)
  end

  private def compile_template(path)
    # Compile template to optimized bytecode
    TemplateCompiler.compile(File.read(path))
  end
end
```

## Network Optimization

### HTTP/2 Optimization

```crystal
# HTTP/2 server push
struct Http2OptimizedEndpoint
  include Endpoint(Http2Request, Http2Response)

  def call : Http2Response
    response = Http2Response.new(@request.data)

    # Server push for critical resources
    response.push("/css/critical.css")
    response.push("/js/app.js")

    response
  end
end
```

### Compression

```crystal
# Response compression
struct CompressedEndpoint
  include Endpoint(CompressRequest, CompressResponse)

  def call : CompressResponse
    response = CompressResponse.new(@request.data)

    # Enable compression for large responses
    if response.size > 1024
      response.compress = true
    end

    response
  end
end
```

## Monitoring and Profiling

### Performance Monitoring

```crystal
# Performance monitoring middleware
struct PerformanceMonitor
  include Handler

  def call(request, response)
    start_time = Time.monotonic
    start_memory = GC.stats.total_allocated

    result = @next.call(request, response)

    duration = Time.monotonic - start_time
    memory_used = GC.stats.total_allocated - start_memory

    record_metrics(request.path, duration, memory_used)

    result
  end
end
```

### Profiling Tools

```crystal
# Crystal profiling integration
require "profile"

# Profile specific endpoints
Profile.start
# ... run your endpoint
Profile.stop

# Analyze results
Profile.print
```

## Configuration Optimization

### Production Configuration

```crystal
# Optimized production configuration
CONFIG.production = {
  # Disable development features
  debug: false,
  hot_reload: false,

  # Optimize for performance
  workers: System.cpu_count,
  backlog: 1024,

  # Memory optimization
  gc_interval: 100,
  gc_threshold: 1000
}
```

### Environment-Specific Tuning

```crystal
# Environment-specific optimizations
case CONFIG.environment
when "development"
  CONFIG.optimization = {
    debug_symbols: true,
    inline_threshold: 0
  }
when "production"
  CONFIG.optimization = {
    debug_symbols: false,
    inline_threshold: 100,
    dead_code_elimination: true
  }
end
```

## Best Practices

### 1. Measure First

```crystal
# Always measure before optimizing
struct MeasuredEndpoint
  include Endpoint(MeasureRequest, MeasureResponse)

  def call : MeasureResponse
    # Measure current performance
    baseline = measure_performance do
      original_implementation
    end

    # Apply optimization
    optimized = measure_performance do
      optimized_implementation
    end

    # Compare results
    improvement = (baseline - optimized) / baseline * 100
    log_optimization(improvement)

    MeasureResponse.new(optimized_result)
  end
end
```

### 2. Profile Regularly

```crystal
# Regular profiling schedule
SCHEDULER.every(1.hour) do
  Profile.start
  # Run representative workload
  Profile.stop

  # Save profile data
  save_profile_data
end
```

### 3. Monitor Production

```crystal
# Production monitoring
struct ProductionMonitor
  include Handler

  def call(request, response)
    # Track key metrics
    track_request_count(request.path)
    track_response_time(request.path, measure_time)
    track_error_rate(request.path, response.status)

    @next.call(request, response)
  end
end
```

## Next Steps

- [Benchmarks](benchmarks.md) - Compare performance metrics
- [Scaling Patterns](scaling.md) - Scale your optimized applications
- [Performance Tuning](advanced/performance-tuning.md) - Advanced optimization techniques

---

_Remember: Premature optimization is the root of all evil. Always measure first, then optimize based on real bottlenecks._

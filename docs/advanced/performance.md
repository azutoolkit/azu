# Performance Optimization

Azu is designed for high performance, but understanding how to optimize your applications can make a significant difference. This guide covers performance monitoring, optimization techniques, and best practices for building fast, scalable applications.

## What is Performance Optimization?

Performance optimization in Azu involves:

- **Monitoring**: Track application performance metrics
- **Profiling**: Identify performance bottlenecks
- **Optimization**: Apply targeted improvements
- **Scaling**: Handle increased load efficiently
- **Caching**: Reduce redundant computations

## Performance Monitoring

### Built-in Metrics

Azu provides comprehensive performance monitoring:

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable performance monitoring
    config.performance_enabled = true
    config.performance_monitor = Azu::PerformanceMonitor.new

    # Configure metrics collection
    config.performance_metrics = {
      request_duration: true,
      memory_usage: true,
      cpu_usage: true,
      database_queries: true,
      cache_hits: true
    }
  end
end
```

### Custom Metrics

```crystal
class CustomMetrics
  def self.record_request_duration(endpoint : String, duration : Time::Span)
    Azu.cache.increment("metrics:request_duration:#{endpoint}")
    Azu.cache.set("metrics:request_duration:#{endpoint}:last", duration.total_milliseconds)
  end

  def self.record_memory_usage(component : String, memory : Int64)
    Azu.cache.increment("metrics:memory_usage:#{component}")
    Azu.cache.set("metrics:memory_usage:#{component}:last", memory)
  end

  def self.record_database_query(query : String, duration : Time::Span)
    Azu.cache.increment("metrics:database_queries:#{query}")
    Azu.cache.set("metrics:database_queries:#{query}:last", duration.total_milliseconds)
  end
end
```

### Performance Dashboard

```crystal
class PerformanceDashboard
  def self.get_metrics : Hash(String, JSON::Any)
    {
      "request_duration" => get_request_duration_metrics,
      "memory_usage" => get_memory_usage_metrics,
      "cpu_usage" => get_cpu_usage_metrics,
      "database_queries" => get_database_query_metrics,
      "cache_performance" => get_cache_performance_metrics
    }
  end

  private def self.get_request_duration_metrics
    # Get request duration metrics
    {
      "average" => Azu.cache.get("metrics:request_duration:average")?.try(&.to_f) || 0.0,
      "max" => Azu.cache.get("metrics:request_duration:max")?.try(&.to_f) || 0.0,
      "min" => Azu.cache.get("metrics:request_duration:min")?.try(&.to_f) || 0.0
    }
  end

  private def self.get_memory_usage_metrics
    # Get memory usage metrics
    {
      "current" => Azu.cache.get("metrics:memory_usage:current")?.try(&.to_i64) || 0,
      "peak" => Azu.cache.get("metrics:memory_usage:peak")?.try(&.to_i64) || 0,
      "average" => Azu.cache.get("metrics:memory_usage:average")?.try(&.to_i64) || 0
    }
  end
end
```

## Database Optimization

### Query Optimization

```crystal
class OptimizedUserService
  def find_user_with_posts(user_id : Int64) : User?
    # Use eager loading to avoid N+1 queries
    User.includes(:posts).find(user_id)
  end

  def find_users_with_posts(limit : Int32 = 10) : Array(User)
    # Use joins instead of separate queries
    User.joins(:posts)
        .select("users.*, COUNT(posts.id) as post_count")
        .group("users.id")
        .limit(limit)
        .to_a
  end

  def find_recent_posts(user_id : Int64, limit : Int32 = 10) : Array(Post)
    # Use indexed columns for filtering
    Post.where(user_id: user_id)
        .where("created_at > ?", 1.week.ago)
        .order(created_at: :desc)
        .limit(limit)
        .to_a
  end
end
```

### Connection Pooling

```crystal
module MyApp
  include Azu

  configure do |config|
    # Database connection pooling
    config.database.pool_size = 20
    config.database.pool_timeout = 30.seconds
    config.database.pool_checkout_timeout = 5.seconds

    # Connection pool monitoring
    config.database.pool_monitoring = true
  end
end
```

### Query Caching

```crystal
class CachedUserService
  def find_user(id : Int64) : User?
    # Cache user data
    Azu.cache.get_or_set("user:#{id}", ttl: 1.hour) do
      User.find(id)
    end
  end

  def find_users_by_role(role : String) : Array(User)
    # Cache role-based queries
    cache_key = "users:role:#{role}"
    Azu.cache.get_or_set(cache_key, ttl: 30.minutes) do
      User.where(role: role).to_a
    end
  end
end
```

## Memory Optimization

### Memory Management

```crystal
class MemoryOptimizedService
  def process_large_dataset(data : Array(DataItem))
    # Process data in chunks to avoid memory spikes
    data.each_slice(100) do |chunk|
      process_chunk(chunk)

      # Force garbage collection for large datasets
      GC.collect if data.size > 1000
    end
  end

  def process_chunk(chunk : Array(DataItem))
    # Process chunk
    chunk.each do |item|
      process_item(item)
    end
  end
end
```

### Object Pooling

```crystal
class ObjectPool
  def initialize(@pool_size : Int32 = 100)
    @pool = [] of ProcessedObject
    @mutex = Mutex.new
  end

  def acquire : ProcessedObject
    @mutex.synchronize do
      if @pool.empty?
        ProcessedObject.new
      else
        @pool.pop
      end
    end
  end

  def release(obj : ProcessedObject)
    @mutex.synchronize do
      if @pool.size < @pool_size
        obj.reset
        @pool << obj
      end
    end
  end
end
```

## Caching Strategies

### Multi-Level Caching

```crystal
class MultiLevelCache
  def get(key : String) : String?
    # L1: Memory cache
    if value = @memory_cache[key]?
      return value
    end

    # L2: Redis cache
    if value = @redis_cache.get(key)
      @memory_cache[key] = value
      return value
    end

    # L3: Database
    if value = @database.get(key)
      @redis_cache.set(key, value, ttl: 1.hour)
      @memory_cache[key] = value
      return value
    end

    nil
  end

  def set(key : String, value : String, ttl : Time::Span = 1.hour)
    # Set in all cache levels
    @memory_cache[key] = value
    @redis_cache.set(key, value, ttl: ttl)
    @database.set(key, value)
  end
end
```

### Cache Warming

```crystal
class CacheWarmer
  def self.warm_frequently_accessed_data
    # Warm user cache
    User.where(active: true).limit(100).each do |user|
      Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)
    end

    # Warm post cache
    Post.recent.limit(50).each do |post|
      Azu.cache.set("post:#{post.id}", post.to_json, ttl: 2.hours)
    end

    # Warm configuration cache
    Azu.cache.set("config:app", AppConfig.to_json, ttl: 1.day)
  end
end
```

## Asynchronous Processing

### Background Jobs

```crystal
class BackgroundJobProcessor
  def self.process_async(job_type : String, data : Hash(String, JSON::Any))
    spawn do
      case job_type
      when "email_notification"
        process_email_notification(data)
      when "data_processing"
        process_data_processing(data)
      when "file_upload"
        process_file_upload(data)
      end
    end
  end

  private def self.process_email_notification(data : Hash(String, JSON::Any))
    # Process email notification
    user_id = data["user_id"].as_i64
    message = data["message"].as_s

    # Send email
    EmailService.send_notification(user_id, message)
  end

  private def self.process_data_processing(data : Hash(String, JSON::Any))
    # Process data
    dataset_id = data["dataset_id"].as_i64

    # Process dataset
    DataProcessor.process_dataset(dataset_id)
  end
end
```

### Async Endpoints

```crystal
struct AsyncEndpoint
  include Azu::Endpoint(AsyncRequest, AsyncResponse)

  post "/async/process"

  def call : AsyncResponse
    # Start background processing
    job_id = start_background_job(async_request.data)

    AsyncResponse.new({
      job_id: job_id,
      status: "processing",
      message: "Job started successfully"
    })
  end

  private def start_background_job(data : Hash(String, JSON::Any)) : String
    job_id = generate_job_id

    # Queue job for processing
    BackgroundJobProcessor.process_async("data_processing", {
      "job_id" => JSON::Any.new(job_id),
      "data" => JSON::Any.new(data)
    })

    job_id
  end
end
```

## WebSocket Optimization

### Connection Pooling

```crystal
class OptimizedWebSocketChannel
  include Azu::Channel

  ws "/optimized"

  def initialize
    @connection_pool = ConnectionPool.new(max_size: 1000)
    @message_queue = [] of String
    @batch_size = 10
    @batch_timeout = 100.milliseconds
  end

  def on_connect
    connection = @connection_pool.acquire
    # Use connection
  end

  def on_close(code, message)
    @connection_pool.release(connection)
  end

  def on_message(message : String)
    @message_queue << message

    if @message_queue.size >= @batch_size
      process_batch
    else
      schedule_batch_processing
    end
  end

  private def process_batch
    messages = @message_queue.dup
    @message_queue.clear

    # Process batch of messages
    process_messages(messages)
  end
end
```

### Message Batching

```crystal
class MessageBatcher
  def initialize(@batch_size : Int32 = 10, @batch_timeout : Time::Span = 100.milliseconds)
    @message_queue = [] of String
    @batch_timer = Timer.new(@batch_timeout) { process_batch }
  end

  def add_message(message : String)
    @message_queue << message

    if @message_queue.size >= @batch_size
      process_batch
    end
  end

  private def process_batch
    return if @message_queue.empty?

    messages = @message_queue.dup
    @message_queue.clear

    # Process batch
    process_messages(messages)
  end
end
```

## Template Optimization

### Template Caching

```crystal
class TemplateCache
  def self.get_cached_template(template : String, data : Hash(String, JSON::Any)) : String?
    cache_key = generate_cache_key(template, data)
    Azu.cache.get(cache_key)
  end

  def self.set_cached_template(template : String, data : Hash(String, JSON::Any), content : String)
    cache_key = generate_cache_key(template, data)
    Azu.cache.set(cache_key, content, ttl: 1.hour)
  end

  private def self.generate_cache_key(template : String, data : Hash(String, JSON::Any)) : String
    "template:#{template}:#{data.hash}"
  end
end
```

### Lazy Loading

```crystal
class LazyTemplateRenderer
  def render_template(template : String, data : Hash(String, JSON::Any)) : String
    # Check cache first
    if cached = TemplateCache.get_cached_template(template, data)
      return cached
    end

    # Render template
    content = render_template_content(template, data)

    # Cache result
    TemplateCache.set_cached_template(template, data, content)

    content
  end
end
```

## Monitoring and Alerting

### Performance Alerts

```crystal
class PerformanceAlerts
  def self.check_performance_metrics
    metrics = PerformanceDashboard.get_metrics

    # Check request duration
    if metrics["request_duration"]["average"].as_f > 1000.0
      send_alert("High request duration: #{metrics["request_duration"]["average"]}ms")
    end

    # Check memory usage
    if metrics["memory_usage"]["current"].as_i64 > 1.gigabyte
      send_alert("High memory usage: #{metrics["memory_usage"]["current"]} bytes")
    end

    # Check database queries
    if metrics["database_queries"]["count"].as_i64 > 1000
      send_alert("High database query count: #{metrics["database_queries"]["count"]}")
    end
  end

  private def self.send_alert(message : String)
    # Send alert via email, Slack, etc.
    Log.warn { "Performance Alert: #{message}" }
  end
end
```

### Health Checks

```crystal
class HealthCheck
  def self.healthy? : Bool
    # Check database connection
    return false unless database_healthy?

    # Check cache connection
    return false unless cache_healthy?

    # Check memory usage
    return false unless memory_healthy?

    # Check disk space
    return false unless disk_healthy?

    true
  end

  private def self.database_healthy? : Bool
    begin
      User.count
      true
    rescue
      false
    end
  end

  private def self.cache_healthy? : Bool
    begin
      Azu.cache.set("health_check", "ok", ttl: 1.minute)
      Azu.cache.get("health_check") == "ok"
    rescue
      false
    end
  end

  private def self.memory_healthy? : Bool
    memory_usage = get_memory_usage
    memory_usage < 2.gigabytes
  end

  private def self.disk_healthy? : Bool
    disk_usage = get_disk_usage
    disk_usage < 0.9  # 90% threshold
  end
end
```

## Best Practices

### 1. Monitor Performance

```crystal
# Good: Monitor performance metrics
class PerformanceMonitor
  def self.record_request_duration(endpoint : String, duration : Time::Span)
    Azu.cache.increment("metrics:request_duration:#{endpoint}")
  end
end

# Avoid: No performance monitoring
# No monitoring - can't identify bottlenecks
```

### 2. Use Caching Strategically

```crystal
# Good: Strategic caching
Azu.cache.set("user:#{id}", user_data, ttl: 1.hour)  # User data
Azu.cache.set("posts:recent", posts_data, ttl: 5.minutes)  # Frequently changing data

# Avoid: Over-caching
Azu.cache.set("user:#{id}", user_data, ttl: 1.day)  # Too long for user data
```

### 3. Optimize Database Queries

```crystal
# Good: Optimized queries
User.includes(:posts).where(active: true).limit(10)

# Avoid: N+1 queries
users = User.where(active: true).limit(10)
users.each { |user| user.posts }  # N+1 query problem
```

### 4. Use Asynchronous Processing

```crystal
# Good: Async processing
spawn process_large_dataset(data)

# Avoid: Blocking operations
process_large_dataset(data)  # Blocks request
```

### 5. Monitor Resource Usage

```crystal
# Good: Monitor resources
class ResourceMonitor
  def self.check_resources
    check_memory_usage
    check_cpu_usage
    check_disk_usage
  end
end

# Avoid: No resource monitoring
# No monitoring - can't identify resource issues
```

## Next Steps

Now that you understand performance optimization:

1. **[Monitoring](monitoring.md)** - Monitor application performance
2. **[Caching](caching.md)** - Implement caching strategies
3. **[Scaling](../deployment/scaling.md)** - Scale your application
4. **[Testing](../testing.md)** - Test performance improvements
5. **[Deployment](../deployment/production.md)** - Deploy with performance optimizations

---

_Performance optimization in Azu is about understanding your application's behavior and applying targeted improvements. With comprehensive monitoring, strategic caching, and efficient resource usage, you can build fast, scalable applications._

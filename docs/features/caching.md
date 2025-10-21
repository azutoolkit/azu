# Caching

Azu provides a comprehensive caching system that helps improve application performance by storing frequently accessed data in memory or external cache stores. With support for multiple cache backends and intelligent invalidation strategies, caching in Azu is both powerful and easy to use.

## What is Caching?

Caching in Azu provides:

- **Performance Optimization**: Reduce database queries and expensive computations
- **Multiple Backends**: Support for memory, Redis, and custom cache stores
- **Intelligent Invalidation**: Automatic cache invalidation based on events
- **Type Safety**: Type-safe cache operations with compile-time guarantees
- **TTL Support**: Time-to-live expiration for cached data

## Basic Caching

### Simple Cache Operations

```crystal
# Set cache value
Azu.cache.set("user:123", user_data, ttl: 1.hour)

# Get cache value
if cached_user = Azu.cache.get("user:123")
  # Use cached data
  process_user(cached_user)
else
  # Cache miss - fetch from database
  user = fetch_user_from_database(123)
  Azu.cache.set("user:123", user.to_json, ttl: 1.hour)
  process_user(user)
end

# Delete cache value
Azu.cache.delete("user:123")

# Check if key exists
if Azu.cache.exists?("user:123")
  # Key exists in cache
end
```

### Cache with Default Values

```crystal
# Get with default value
user_data = Azu.cache.get("user:123") || fetch_user_from_database(123)

# Get or set pattern
user_data = Azu.cache.get_or_set("user:123", ttl: 1.hour) do
  fetch_user_from_database(123)
end
```

## Cache Configuration

### Basic Configuration

```crystal
module MyApp
  include Azu

  configure do |config|
    # Cache configuration
    config.cache.backend = :memory
    config.cache.default_ttl = 1.hour
    config.cache.max_size = 1000
    config.cache.compression = true
  end
end
```

### Redis Configuration

```crystal
module MyApp
  include Azu

  configure do |config|
    # Redis cache configuration
    config.cache.backend = :redis
    config.cache.redis.host = "localhost"
    config.cache.redis.port = 6379
    config.cache.redis.database = 0
    config.cache.redis.password = "secret"
    config.cache.redis.ssl = false
  end
end
```

### Custom Cache Backend

```crystal
class CustomCacheBackend
  include Azu::Cache::Backend

  def initialize(@storage : Hash(String, String))
  end

  def get(key : String) : String?
    @storage[key]?
  end

  def set(key : String, value : String, ttl : Time::Span? = nil) : Bool
    @storage[key] = value
    true
  end

  def delete(key : String) : Bool
    @storage.delete(key)
    true
  end

  def exists?(key : String) : Bool
    @storage.has_key?(key)
  end

  def clear : Bool
    @storage.clear
    true
  end
end

# Use custom backend
module MyApp
  include Azu

  configure do |config|
    config.cache.backend = CustomCacheBackend.new({} of String => String)
  end
end
```

## Cache Patterns

### Cache-Aside Pattern

```crystal
class UserService
  def find_user(id : Int64) : User?
    # Try cache first
    if cached_data = Azu.cache.get("user:#{id}")
      return User.from_json(cached_data)
    end

    # Cache miss - fetch from database
    user = User.find(id)
    return nil unless user

    # Store in cache
    Azu.cache.set("user:#{id}", user.to_json, ttl: 1.hour)
    user
  end

  def update_user(user : User)
    # Update database
    user.save

    # Invalidate cache
    Azu.cache.delete("user:#{user.id}")

    # Optionally pre-warm cache
    Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)
  end
end
```

### Write-Through Pattern

```crystal
class UserService
  def create_user(user_data : Hash(String, JSON::Any)) : User
    user = User.new(user_data)

    # Save to database
    user.save

    # Write to cache
    Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)

    user
  end

  def update_user(user : User)
    # Update database
    user.save

    # Update cache
    Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)
  end
end
```

### Write-Behind Pattern

```crystal
class UserService
  def initialize
    @write_queue = [] of {key: String, value: String, ttl: Time::Span?}
    @write_interval = 5.seconds
    @write_timer = Timer.new(@write_interval) { flush_write_queue }
  end

  def update_user(user : User)
    # Update cache immediately
    Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)

    # Queue for database write
    @write_queue << {key: "user:#{user.id}", value: user.to_json, ttl: 1.hour}
  end

  private def flush_write_queue
    return if @write_queue.empty?

    # Batch write to database
    batch_update_users(@write_queue)
    @write_queue.clear
  end
end
```

## Cache Invalidation

### Time-Based Invalidation

```crystal
class UserService
  def find_user(id : Int64) : User?
    # Cache with TTL
    Azu.cache.get_or_set("user:#{id}", ttl: 1.hour) do
      User.find(id)
    end
  end

  def find_active_users : Array(User)
    # Cache with shorter TTL for frequently changing data
    Azu.cache.get_or_set("active_users", ttl: 5.minutes) do
      User.where(active: true).to_a
    end
  end
end
```

### Event-Based Invalidation

```crystal
class UserService
  def update_user(user : User)
    # Update database
    user.save

    # Invalidate related caches
    invalidate_user_caches(user.id)
  end

  def delete_user(user : User)
    # Delete from database
    user.delete

    # Invalidate all user-related caches
    invalidate_user_caches(user.id)
  end

  private def invalidate_user_caches(user_id : Int64)
    # Invalidate specific user cache
    Azu.cache.delete("user:#{user_id}")

    # Invalidate user list caches
    Azu.cache.delete("users:all")
    Azu.cache.delete("users:active")
    Azu.cache.delete("users:inactive")

    # Invalidate user posts cache
    Azu.cache.delete("user:#{user_id}:posts")
  end
end
```

### Tag-Based Invalidation

```crystal
class UserService
  def find_user(id : Int64) : User?
    # Cache with tags
    Azu.cache.get_or_set("user:#{id}", ttl: 1.hour, tags: ["user", "user:#{id}"]) do
      User.find(id)
    end
  end

  def invalidate_user_tag(user_id : Int64)
    # Invalidate all caches with user tag
    Azu.cache.delete_by_tag("user:#{user_id}")
  end

  def invalidate_all_users
    # Invalidate all caches with user tag
    Azu.cache.delete_by_tag("user")
  end
end
```

## Cache Warming

### Preload Cache

```crystal
class CacheWarmer
  def self.warm_user_cache
    # Preload frequently accessed users
    User.where(active: true).limit(100).each do |user|
      Azu.cache.set("user:#{user.id}", user.to_json, ttl: 1.hour)
    end

    # Preload user lists
    Azu.cache.set("users:active", User.where(active: true).to_json, ttl: 30.minutes)
    Azu.cache.set("users:inactive", User.where(active: false).to_json, ttl: 30.minutes)
  end

  def self.warm_post_cache
    # Preload recent posts
    Post.recent.limit(50).each do |post|
      Azu.cache.set("post:#{post.id}", post.to_json, ttl: 2.hours)
    end
  end
end
```

### Lazy Loading

```crystal
class LazyCacheLoader
  def self.load_user_posts(user_id : Int64) : Array(Post)
    # Try cache first
    if cached_posts = Azu.cache.get("user:#{user_id}:posts")
      return Array(Post).from_json(cached_posts)
    end

    # Load from database
    posts = Post.where(user_id: user_id).to_a

    # Cache for future requests
    Azu.cache.set("user:#{user_id}:posts", posts.to_json, ttl: 1.hour)

    posts
  end
end
```

## Cache Monitoring

### Cache Metrics

```crystal
class CacheMetrics
  def self.record_hit(key : String)
    # Record cache hit
    Azu.cache.increment("cache:hits:#{key}")
  end

  def self.record_miss(key : String)
    # Record cache miss
    Azu.cache.increment("cache:misses:#{key}")
  end

  def self.get_hit_rate(key : String) : Float64
    hits = Azu.cache.get("cache:hits:#{key}")?.try(&.to_i) || 0
    misses = Azu.cache.get("cache:misses:#{key}")?.try(&.to_i) || 0
    total = hits + misses

    return 0.0 if total == 0
    hits.to_f / total
  end
end
```

### Cache Health Check

```crystal
class CacheHealthCheck
  def self.healthy? : Bool
    begin
      # Test cache operations
      test_key = "health_check:#{Time.utc.to_unix}"
      test_value = "test_value"

      # Set test value
      Azu.cache.set(test_key, test_value, ttl: 1.minute)

      # Get test value
      retrieved = Azu.cache.get(test_key)

      # Clean up
      Azu.cache.delete(test_key)

      # Check if value was retrieved correctly
      retrieved == test_value
    rescue
      false
    end
  end
end
```

## Cache Testing

### Unit Testing

```crystal
require "spec"

describe "Cache" do
  it "stores and retrieves values" do
    key = "test_key"
    value = "test_value"

    Azu.cache.set(key, value)
    retrieved = Azu.cache.get(key)

    retrieved.should eq(value)
  end

  it "respects TTL" do
    key = "test_key_ttl"
    value = "test_value"

    Azu.cache.set(key, value, ttl: 1.second)
    sleep 2.seconds

    retrieved = Azu.cache.get(key)
    retrieved.should be_nil
  end

  it "deletes values" do
    key = "test_key_delete"
    value = "test_value"

    Azu.cache.set(key, value)
    Azu.cache.delete(key)

    retrieved = Azu.cache.get(key)
    retrieved.should be_nil
  end
end
```

### Integration Testing

```crystal
describe "Cache Integration" do
  it "handles cache misses gracefully" do
    service = UserService.new

    # Ensure cache is empty
    Azu.cache.delete("user:999")

    # Should fetch from database
    user = service.find_user(999)

    # Should be cached for next request
    cached_user = service.find_user(999)
    cached_user.should eq(user)
  end

  it "invalidates cache on updates" do
    service = UserService.new
    user = User.new("Alice", "alice@example.com")

    # Cache user
    service.find_user(user.id)

    # Update user
    user.name = "Alice Updated"
    service.update_user(user)

    # Should fetch fresh data
    updated_user = service.find_user(user.id)
    updated_user.name.should eq("Alice Updated")
  end
end
```

## Performance Considerations

### Cache Size Management

```crystal
class CacheSizeManager
  def self.manage_cache_size
    # Get cache size
    size = Azu.cache.size

    if size > 1000
      # Evict least recently used items
      evict_lru_items(100)
    end
  end

  private def self.evict_lru_items(count : Int32)
    # Implementation depends on cache backend
    # For memory cache, remove oldest items
    # For Redis, use LRU eviction policy
  end
end
```

### Cache Compression

```crystal
class CompressedCache
  def self.set_compressed(key : String, value : String, ttl : Time::Span? = nil)
    # Compress value before storing
    compressed = compress(value)
    Azu.cache.set(key, compressed, ttl: ttl)
  end

  def self.get_compressed(key : String) : String?
    if compressed = Azu.cache.get(key)
      decompress(compressed)
    end
  end

  private def self.compress(data : String) : String
    # Implement compression
    data
  end

  private def self.decompress(data : String) : String
    # Implement decompression
    data
  end
end
```

## Best Practices

### 1. Use Appropriate TTL

```crystal
# Good: Appropriate TTL for different data types
Azu.cache.set("user:#{id}", user_data, ttl: 1.hour)        # User data
Azu.cache.set("posts:recent", posts_data, ttl: 5.minutes) # Frequently changing data
Azu.cache.set("config:app", config_data, ttl: 1.day)      # Static configuration
```

### 2. Handle Cache Failures

```crystal
class ResilientCache
  def self.get_with_fallback(key : String, &block)
    begin
      Azu.cache.get(key) || yield
    rescue e
      Log.warn(exception: e) { "Cache error, using fallback" }
      yield
    end
  end
end
```

### 3. Use Cache Keys Consistently

```crystal
# Good: Consistent key naming
"user:#{id}"
"user:#{id}:posts"
"user:#{id}:settings"
"posts:recent"
"posts:popular"

# Avoid: Inconsistent naming
"user_#{id}"
"User:#{id}"
"user-#{id}"
```

### 4. Monitor Cache Performance

```crystal
class CacheMonitor
  def self.monitor_performance
    # Track cache hit rate
    # Monitor cache size
    # Alert on cache failures
    # Log cache statistics
  end
end
```

### 5. Test Cache Behavior

```crystal
describe "Cache Behavior" do
  it "handles cache failures gracefully" do
    # Mock cache failure
    allow(Azu.cache).to receive(:get).and_raise(CacheError.new)

    # Should fall back to database
    user = UserService.new.find_user(123)
    user.should_not be_nil
  end
end
```

## Next Steps

Now that you understand caching:

1. **[Performance](../advanced/performance.md)** - Optimize application performance
2. **[Monitoring](../advanced/monitoring.md)** - Monitor cache performance
3. **[Testing](../testing.md)** - Test cache behavior
4. **[Deployment](../deployment/production.md)** - Deploy with caching
5. **[Scaling](../deployment/scaling.md)** - Scale with caching

---

_Caching in Azu provides a powerful way to improve application performance. With multiple backends, intelligent invalidation, and comprehensive monitoring, it makes building high-performance applications straightforward and reliable._

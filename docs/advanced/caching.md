# Caching

Azu provides a powerful and flexible caching system similar to Rails.cache, supporting multiple storage backends and Rails-like API patterns. The caching system is designed for high performance and thread safety.

## Table of Contents

- [Basic Usage](#basic-usage)
- [Configuration](#configuration)
- [Cache Stores](#cache-stores)
- [Advanced Usage](#advanced-usage)
- [Performance Considerations](#performance-considerations)
- [Best Practices](#best-practices)
- [API Reference](#api-reference)
- [Usage Patterns Comparison](#usage-patterns-comparison)
- [Troubleshooting](#troubleshooting)

## Dependencies

### Redis Installation

To use the Redis cache store, you need to have Redis server installed and running.

#### Installing Redis

**macOS (Homebrew):**

```bash
brew install redis
brew services start redis
```

**Ubuntu/Debian:**

```bash
sudo apt update
sudo apt install redis-server
sudo systemctl start redis-server
sudo systemctl enable redis-server
```

**CentOS/RHEL:**

```bash
sudo yum install redis
sudo systemctl start redis
sudo systemctl enable redis
```

**Docker:**

```bash
# Run Redis in Docker
docker run -d --name redis -p 6379:6379 redis:latest

# Or with persistence
docker run -d --name redis -p 6379:6379 -v redis_data:/data redis:latest redis-server --appendonly yes
```

#### Verifying Redis Installation

```bash
# Test Redis connectivity
redis-cli ping
# Should return: PONG

# Check Redis version
redis-cli info server | grep redis_version
```

### Azu Dependencies

Add Redis to your `shard.yml`:

```yaml
dependencies:
  redis:
    github: stefanwille/crystal-redis
    version: ~> 2.9.0
```

Then install dependencies:

```bash
shards install
```

## Basic Usage

### Simple Get/Set Operations

```crystal
# Basic cache operations
Azu.cache.set("user:123", user_data, ttl: 1.hour)
cached_user = Azu.cache.get("user:123")

# Check if key exists
if Azu.cache.exists?("user:123")
  puts "User data is cached"
end

# Delete cached data
Azu.cache.delete("user:123")
```

### Get with Block Syntax (Rails-like)

The `get` method supports block syntax with TTL, providing an alternative to `fetch`:

```crystal
# Cache expensive operations using get with block
user_data = Azu.cache.get("user:#{user_id}", ttl: 1.hour) do
  # This block only runs if the key is not cached
  database.query("SELECT * FROM users WHERE id = ?", user_id)
end

# Complex data processing with get syntax
analytics_data = Azu.cache.get("analytics:#{date}", ttl: 1.day) do
  expensive_analytics_calculation(date)
end
```

### Fetch with Block (Rails-like)

The `fetch` method provides the traditional Rails caching pattern:

```crystal
# Cache expensive operations using fetch
user_data = Azu.cache.fetch("user:#{user_id}", ttl: 30.minutes) do
  # This block only runs if the key is not cached
  database.query("SELECT * FROM users WHERE id = ?", user_id)
end

# Complex data processing
analytics_data = Azu.cache.fetch("analytics:#{date}", ttl: 1.day) do
  expensive_analytics_calculation(date)
end
```

### Endpoint Example

```crystal
struct UserEndpoint
  include Endpoint(UserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # Using fetch method
    user_data = Azu.cache.fetch("user:#{request.id}", ttl: 15.minutes) do
      # Expensive database query
      User.find(request.id).to_json
    end

    UserResponse.new(JSON.parse(user_data))
  end
end

# Alternative using get with block syntax
struct UserEndpointAlt
  include Endpoint(UserRequest, UserResponse)

  get "/users-alt/:id"

  def call : UserResponse
    # Using get method with block
    user_data = Azu.cache.get("user:#{request.id}", ttl: 15.minutes) do
      # Expensive database query
      User.find(request.id).to_json
    end

    UserResponse.new(JSON.parse(user_data))
  end
end
```

## Configuration

### Environment Variables

Configure caching behavior through environment variables:

```bash
# Enable/disable caching (default: true)
CACHE_ENABLED=true

# Cache store type (default: memory)
CACHE_STORE=memory

# Maximum cache size for memory store (default: 1000)
CACHE_MAX_SIZE=5000

# Default TTL in seconds (default: 3600)
CACHE_DEFAULT_TTL=7200

# Key prefix for all cache keys (default: azu)
CACHE_KEY_PREFIX=myapp

# Enable compression (default: false)
CACHE_COMPRESS=false

# Enable serialization (default: true)
CACHE_SERIALIZE=true
```

### Programmatic Configuration

```crystal
# Configure cache in application setup
Azu.configure do |config|
  config.cache_config.enabled = true
  config.cache_config.store = "memory"
  config.cache_config.max_size = 2000
  config.cache_config.default_ttl = 3600
  config.cache_config.key_prefix = "myapp"
end
```

## Cache Stores

### Memory Store (Default)

Thread-safe, in-memory cache with LRU eviction:

```crystal
# Automatic with default configuration
Azu.cache.set("key", "value")

# Manual configuration
config = Azu::Cache::Configuration.new
config.store = "memory"
config.max_size = 1000
cache = Azu::Cache::Manager.new(config)
```

**Features:**

- Thread-safe with mutex protection
- LRU (Least Recently Used) eviction
- TTL support with automatic cleanup
- Memory usage tracking
- Access statistics

### Redis Store

Distributed cache with Redis backend for multi-server deployments:

```crystal
# Configure Redis cache
ENV["CACHE_STORE"] = "redis"
ENV["CACHE_REDIS_URL"] = "redis://localhost:6379/0"

# Or programmatically
config = Azu::Cache::Configuration.new
config.store = "redis"
config.redis_url = "redis://localhost:6379/1"
config.redis_pool_size = 10
config.redis_timeout = 5
cache = Azu::Cache::Manager.new(config)
```

**Features:**

- Connection pooling for thread safety
- Native Redis operations for better performance
- Automatic failover and error handling
- Supports all Redis data types
- TTL support with Redis EXPIRE
- Atomic increment/decrement operations
- Multi-key operations with Redis pipelines

**Redis Configuration:**

| Environment Variable    | Default                    | Description                   |
| ----------------------- | -------------------------- | ----------------------------- |
| `CACHE_REDIS_URL`       | `redis://localhost:6379/0` | Redis connection URL          |
| `CACHE_REDIS_POOL_SIZE` | `5`                        | Connection pool size          |
| `CACHE_REDIS_TIMEOUT`   | `5`                        | Connection timeout in seconds |

```crystal
# Redis URL formats
"redis://localhost:6379/0"                    # Basic
"redis://user:password@localhost:6379/1"      # With auth
"redis://localhost:6379/2?timeout=10"         # With options
"rediss://localhost:6380/0"                   # SSL/TLS
```

### Null Store

Disabled cache for testing or when caching is not needed:

```crystal
# Disable caching
ENV["CACHE_ENABLED"] = "false"

# Or programmatically
config = Azu::Cache::Configuration.new
config.enabled = false
cache = Azu::Cache::Manager.new(config)
```

## Advanced Usage

### Counter Operations

```crystal
# Page view counter
Azu.cache.increment("page_views:#{page_id}")
Azu.cache.increment("page_views:#{page_id}", 5)  # Increment by 5

# Decrement counters
Azu.cache.decrement("inventory:#{product_id}")
Azu.cache.decrement("inventory:#{product_id}", 3)  # Decrement by 3

# Rate limiting example
struct RateLimitedEndpoint
  include Endpoint(RateLimitRequest, RateLimitResponse)

  def call : RateLimitResponse
    key = "rate_limit:#{request.ip}"
    current_count = Azu.cache.increment(key, ttl: 1.minute) || 0

    if current_count > 100
      raise Azu::Response::Error.new("Rate limit exceeded", 429)
    end

    RateLimitResponse.new(current_count)
  end
end
```

### Multi-Key Operations

```crystal
# Get multiple keys at once
keys = ["user:1", "user:2", "user:3"]
results = Azu.cache.get_multi(keys)
results.each do |key, value|
  puts "#{key}: #{value}"
end

# Set multiple keys at once
values = {
  "user:1" => user1_data,
  "user:2" => user2_data,
  "user:3" => user3_data
}
Azu.cache.set_multi(values, ttl: 30.minutes)
```

### Time Convenience Methods

```crystal
# Use convenience methods for time spans
Azu.cache.set("key", "value", ttl: 5.minutes)
Azu.cache.set("key", "value", ttl: 2.hours)
Azu.cache.set("key", "value", ttl: 1.day)

# These extend Integer types
5.minutes   # => Time::Span.new(minutes: 5)
2.hours     # => Time::Span.new(hours: 2)
1.day       # => Time::Span.new(days: 1)
```

### Cache Statistics

```crystal
# Get cache performance stats
stats = Azu.cache.stats
puts "Cache enabled: #{stats["enabled"]}"
puts "Store type: #{stats["store_type"]}"
puts "Current size: #{stats["size"]}"
puts "Hit rate: #{stats["hit_rate"]}%"
puts "Memory usage: #{stats["memory_usage_mb"]} MB"
```

### Redis Performance Benefits

Redis store provides significant advantages for distributed applications:

```crystal
# Redis-optimized counter operations
struct PageViewEndpoint
  include Endpoint(PageViewRequest, PageViewResponse)

  post "/page-views/:page_id"

  def call : PageViewResponse
    # Uses Redis INCR command for atomic increment
    count = Azu.cache.increment("page_views:#{request.page_id}") || 0

    # Set daily expiration using Redis EXPIRE
    if count == 1
      Azu.cache.increment("page_views:#{request.page_id}", 0, ttl: 1.day)
    end

    PageViewResponse.new(request.page_id, count)
  end
end

# Redis multi-key operations for better performance
struct UserBatchEndpoint
  include Endpoint(UserBatchRequest, UserBatchResponse)

  get "/users/batch"

  def call : UserBatchResponse
    user_ids = request.user_ids
    cache_keys = user_ids.map { |id| "user:#{id}" }

    # Single Redis MGET command instead of multiple GET commands
    cached_users = Azu.cache.get_multi(cache_keys)

    # Process results efficiently
    users = user_ids.map do |user_id|
      key = "user:#{user_id}"
      cached_users[key] || fetch_user_from_db(user_id)
    end

    UserBatchResponse.new(users)
  end
end
```

### Redis Connection Management

```crystal
# Connection pooling automatically handles concurrent requests
struct HighTrafficEndpoint
  include Endpoint(HighTrafficRequest, HighTrafficResponse)

  def call : HighTrafficResponse
    # Multiple concurrent requests share the Redis connection pool
    data = Azu.cache.fetch("high_traffic_data", ttl: 1.minute) do
      expensive_calculation()
    end

    HighTrafficResponse.new(data)
  end
end

# Redis health checking
struct HealthCheckEndpoint
  include Endpoint(HealthCheckRequest, HealthCheckResponse)

  get "/health"

  def call : HealthCheckResponse
    redis_status = if Azu.cache.ping == "PONG"
                     "healthy"
                   else
                     "unhealthy"
                   end

    HealthCheckResponse.new(redis_status)
  end
end
```

## Performance Considerations

### Memory Store Performance

- **Thread Safety**: Uses mutex for thread-safe operations
- **LRU Eviction**: Efficiently manages memory usage
- **Cleanup**: Automatic expired entry cleanup
- **Access Tracking**: Maintains access order for LRU

### Optimization Tips

```crystal
# Use appropriate TTL values
Azu.cache.set("frequently_accessed", data, ttl: 5.minutes)
Azu.cache.set("rarely_accessed", data, ttl: 1.hour)

# Batch operations when possible
Azu.cache.set_multi(multiple_values, ttl: 30.minutes)

# Use key prefixes for organization
Azu.cache.set("user:profile:#{id}", profile_data)
Azu.cache.set("user:settings:#{id}", settings_data)
```

### Cache Key Design

```crystal
# Good: Hierarchical keys
"user:123:profile"
"user:123:settings"
"analytics:2024-01-15:page_views"

# Good: Include version for cache invalidation
"user:123:profile:v2"
"api:response:v1.2:users"

# Avoid: Very long keys
"user_profile_with_all_settings_and_preferences_123"
```

## Best Practices

### 1. Use Appropriate TTL Values

```crystal
# Short TTL for frequently changing data
Azu.cache.set("stock_price:#{symbol}", price, ttl: 1.minute)

# Medium TTL for user data
Azu.cache.set("user:#{id}", user_data, ttl: 15.minutes)

# Long TTL for static data
Azu.cache.set("config:#{key}", config_value, ttl: 1.hour)
```

### 2. Handle Cache Misses Gracefully

```crystal
def get_user_data(user_id)
  Azu.cache.fetch("user:#{user_id}", ttl: 15.minutes) do
    begin
      database.get_user(user_id).to_json
    rescue DatabaseError
      # Return default data if database is unavailable
      default_user_data(user_id).to_json
    end
  end
end
```

### 3. Cache Invalidation Strategies

```crystal
# Time-based invalidation (automatic)
Azu.cache.set("user:#{id}", data, ttl: 30.minutes)

# Manual invalidation
def update_user(user_id, new_data)
  User.update(user_id, new_data)
  Azu.cache.delete("user:#{user_id}")
end

# Pattern-based invalidation (for related data)
def clear_user_cache(user_id)
  # Clear all user-related cache entries
  Azu.cache.delete("user:#{user_id}")
  Azu.cache.delete("user:#{user_id}:profile")
  Azu.cache.delete("user:#{user_id}:settings")
end
```

### 4. Testing with Cache

```crystal
# Disable cache in tests
ENV["CACHE_ENABLED"] = "false"

# Or use a separate cache instance for testing
config = Azu::Cache::Configuration.new
config.store = "memory"
config.max_size = 100
test_cache = Azu::Cache::Manager.new(config)

# Clear cache between tests
Azu.cache.clear
```

## API Reference

### Core Methods

```crystal
# Get value from cache
Azu.cache.get(key : String) : String?

# Get value from cache with block and TTL (Rails-like)
Azu.cache.get(key : String, ttl : Time::Span? = nil, &block : -> String) : String

# Set value in cache
Azu.cache.set(key : String, value : String, ttl : Time::Span? = nil) : Bool

# Fetch with block (Rails-like)
Azu.cache.fetch(key : String, ttl : Time::Span? = nil, &block : -> String) : String

# Check if key exists
Azu.cache.exists?(key : String) : Bool

# Delete key
Azu.cache.delete(key : String) : Bool

# Clear all cache
Azu.cache.clear : Bool

# Get cache size
Azu.cache.size : Int32
```

### Counter Operations

```crystal
# Increment counter
Azu.cache.increment(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?

# Decrement counter
Azu.cache.decrement(key : String, amount : Int32 = 1, ttl : Time::Span? = nil) : Int32?
```

### Multi-Key Operations

```crystal
# Get multiple keys
Azu.cache.get_multi(keys : Array(String)) : Hash(String, String?)

# Set multiple keys
Azu.cache.set_multi(values : Hash(String, String), ttl : Time::Span? = nil) : Bool
```

### Statistics

```crystal
# Get cache statistics
Azu.cache.stats : Hash(String, Int32 | Float64 | String)
```

## Environment Variables Reference

| Variable                | Default                    | Description                                  |
| ----------------------- | -------------------------- | -------------------------------------------- |
| `CACHE_ENABLED`         | `true`                     | Enable/disable caching                       |
| `CACHE_STORE`           | `memory`                   | Cache store type (`memory`, `redis`, `null`) |
| `CACHE_MAX_SIZE`        | `1000`                     | Maximum cache entries (memory store)         |
| `CACHE_DEFAULT_TTL`     | `3600`                     | Default TTL in seconds                       |
| `CACHE_KEY_PREFIX`      | `azu`                      | Prefix for all cache keys                    |
| `CACHE_COMPRESS`        | `false`                    | Enable compression                           |
| `CACHE_SERIALIZE`       | `true`                     | Enable serialization                         |
| `CACHE_REDIS_URL`       | `redis://localhost:6379/0` | Redis connection URL                         |
| `CACHE_REDIS_POOL_SIZE` | `5`                        | Redis connection pool size                   |
| `CACHE_REDIS_TIMEOUT`   | `5`                        | Redis connection timeout (seconds)           |

## Error Handling

The cache system is designed to be resilient:

- **Disabled Cache**: When caching is disabled, all operations return safely
- **Memory Limits**: LRU eviction prevents memory exhaustion
- **Thread Safety**: Mutex protection ensures safe concurrent access
- **Graceful Degradation**: Failed cache operations don't break application flow

```crystal
# Cache operations never throw exceptions
result = Azu.cache.get("key")  # Returns nil if not found
success = Azu.cache.set("key", "value")  # Returns false if failed
```

## Usage Patterns Comparison

Azu provides multiple ways to cache data, giving you flexibility to choose the pattern that best fits your coding style:

### Pattern 1: Traditional Get/Set

```crystal
# Check cache first, set if missing
user_data = Azu.cache.get("user:#{user_id}")
if user_data.nil?
  user_data = fetch_user_from_database(user_id)
  Azu.cache.set("user:#{user_id}", user_data, ttl: 1.hour)
end
```

### Pattern 2: Get with Block (Rails-like)

```crystal
# All-in-one: get or execute block and cache
user_data = Azu.cache.get("user:#{user_id}", ttl: 1.hour) do
  fetch_user_from_database(user_id)
end
```

### Pattern 3: Fetch with Block (Traditional Rails)

```crystal
# Traditional Rails pattern
user_data = Azu.cache.fetch("user:#{user_id}", ttl: 1.hour) do
  fetch_user_from_database(user_id)
end
```

Both patterns 2 and 3 are functionally equivalent and provide the same caching behavior. Choose the one that feels more natural to your coding style.

This caching system provides a solid foundation for building high-performance web applications with Azu, offering both simplicity for basic use cases and powerful features for advanced scenarios.

## Troubleshooting

### Common Redis Issues

#### Connection Refused

**Problem:** `Redis operation failed: Connection refused`

**Solutions:**

1. Check if Redis is running:

   ```bash
   redis-cli ping
   ```

2. Start Redis service:

   ```bash
   # macOS
   brew services start redis

   # Linux
   sudo systemctl start redis-server
   ```

3. Check Redis configuration:
   ```bash
   # Check Redis config
   redis-cli config get bind
   redis-cli config get port
   ```

#### Authentication Errors

**Problem:** `Redis operation failed: NOAUTH Authentication required`

**Solution:** Configure Redis password in your cache URL:

```crystal
config.redis_url = "redis://:your-password@localhost:6379/0"
```

#### Connection Pool Timeout

**Problem:** `Redis connection pool timeout`

**Solutions:**

1. Increase pool size:

   ```crystal
   config.redis_pool_size = 20
   ```

2. Increase timeout:

   ```crystal
   config.redis_timeout = 10  # seconds
   ```

3. Check for connection leaks in your code

#### Memory Issues

**Problem:** Redis running out of memory

**Solutions:**

1. Configure Redis max memory:

   ```bash
   redis-cli config set maxmemory 256mb
   redis-cli config set maxmemory-policy allkeys-lru
   ```

2. Use appropriate TTL values:

   ```crystal
   Azu.cache.set("key", "value", ttl: 1.hour)  # Not permanent
   ```

3. Monitor Redis memory usage:
   ```bash
   redis-cli info memory
   ```

### Performance Optimization

#### Redis Configuration

For production use, consider these Redis configuration optimizations:

```bash
# In redis.conf or via redis-cli config set

# Enable persistence (choose one)
save 900 1          # Save if at least 1 key changed in 900 seconds
# OR
appendonly yes      # Append-only file for durability

# Memory optimization
maxmemory-policy allkeys-lru
tcp-keepalive 300

# Network optimization
tcp-backlog 511
timeout 300
```

#### Connection Pooling Best Practices

```crystal
# Production configuration
config = Azu::Cache::Configuration.new
config.store = "redis"
config.redis_url = ENV["REDIS_URL"]
config.redis_pool_size = 20        # Adjust based on concurrency needs
config.redis_timeout = 5           # Connection timeout in seconds
config.default_ttl = 3600          # 1 hour default TTL
```

### Monitoring Redis

#### Health Checks

```crystal
struct RedisHealthCheck
  def self.healthy? : Bool
    begin
      Azu.cache.ping == "PONG"
    rescue
      false
    end
  end

  def self.stats : Hash(String, String)
    info = Azu.cache.redis_info
    return {"status" => "unavailable"} unless info

    {
      "status" => "healthy",
      "redis_version" => info["redis_version"]? || "unknown",
      "connected_clients" => info["connected_clients"]? || "0",
      "used_memory_human" => info["used_memory_human"]? || "0",
      "keyspace_hits" => info["keyspace_hits"]? || "0",
      "keyspace_misses" => info["keyspace_misses"]? || "0"
    }
  end
end
```

#### Key Metrics to Monitor

- **Memory usage:** `used_memory` and `used_memory_peak`
- **Hit ratio:** `keyspace_hits` / (`keyspace_hits` + `keyspace_misses`)
- **Connected clients:** `connected_clients`
- **Operations per second:** `instantaneous_ops_per_sec`
- **Network usage:** `instantaneous_input_kbps`, `instantaneous_output_kbps`

This caching system provides a solid foundation for building high-performance web applications with Azu, offering both simplicity for basic use cases and powerful features for advanced scenarios.

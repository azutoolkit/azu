# How to Set Up Redis Cache

This guide shows you how to configure and use Redis for caching in Azu.

## Prerequisites

Add the Redis shard to your `shard.yml`:

```yaml
dependencies:
  redis:
    github: stefanwille/crystal-redis
    version: ~> 2.9.0
```

Run `shards install`.

## Basic Setup

Configure the Redis cache store:

```crystal
require "redis"

Azu.configure do |config|
  config.cache = Azu::Cache::RedisStore.new(
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  )
end
```

## Using the Redis Cache

### Store and Retrieve Values

```crystal
# Store a value
Azu.cache.set("user:1", user.to_json)

# Store with expiration
Azu.cache.set("session:abc", session_data, expires_in: 30.minutes)

# Retrieve
data = Azu.cache.get("user:1")
```

### Fetch Pattern

```crystal
user_json = Azu.cache.fetch("user:#{id}", expires_in: 1.hour) do
  User.find(id).to_json
end
```

### Delete Keys

```crystal
# Single key
Azu.cache.delete("user:1")

# Pattern-based deletion
Azu.cache.delete_matched("user:*")
```

### Increment/Decrement

```crystal
# Increment a counter
Azu.cache.increment("page_views:home")
Azu.cache.increment("api_calls:user:1", by: 1)

# Decrement
Azu.cache.decrement("available_slots")
```

## Connection Pool

Use connection pooling for better performance:

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::RedisStore.new(
    url: ENV["REDIS_URL"],
    pool_size: 10,
    pool_timeout: 5.seconds
  )
end
```

## Redis Configuration Options

```crystal
Azu::Cache::RedisStore.new(
  url: "redis://localhost:6379/0",
  pool_size: 10,
  pool_timeout: 5.seconds,
  default_ttl: 1.hour,
  namespace: "myapp",
  ssl: false,
  password: ENV["REDIS_PASSWORD"]?
)
```

## Namespacing

Use namespaces to organize and isolate cache data:

```crystal
# Production namespace
config.cache = Azu::Cache::RedisStore.new(
  url: ENV["REDIS_URL"],
  namespace: "myapp:production"
)

# Test namespace
config.cache = Azu::Cache::RedisStore.new(
  url: ENV["REDIS_URL"],
  namespace: "myapp:test"
)
```

Keys are automatically prefixed:
- `user:1` becomes `myapp:production:user:1`

## Caching Complex Objects

Serialize objects for caching:

```crystal
# Cache a user with associations
def cache_user(user : User)
  data = {
    id: user.id,
    name: user.name,
    email: user.email,
    posts: user.posts.map { |p| {id: p.id, title: p.title} }
  }
  Azu.cache.set("user:#{user.id}:full", data.to_json, expires_in: 15.minutes)
end

# Retrieve
def get_cached_user(id : Int64)
  json = Azu.cache.get("user:#{id}:full")
  JSON.parse(json) if json
end
```

## Cache-Aside Pattern

```crystal
struct ProductEndpoint
  include Azu::Endpoint(EmptyRequest, ProductResponse)

  get "/products/:id"

  def call : ProductResponse
    product_id = params["id"]

    # Try cache first
    cached = Azu.cache.get("product:#{product_id}")
    return ProductResponse.from_json(cached) if cached

    # Cache miss - load from database
    product = Product.find(product_id.to_i64)
    response = ProductResponse.new(product)

    # Store in cache
    Azu.cache.set("product:#{product_id}", response.to_json, expires_in: 1.hour)

    response
  end
end
```

## Write-Through Caching

Update cache when data changes:

```crystal
class Product
  include CQL::Model(Product, Int64)

  after_save :update_cache
  after_destroy :remove_from_cache

  private def update_cache
    Azu.cache.set("product:#{id}", to_json, expires_in: 1.hour)
  end

  private def remove_from_cache
    Azu.cache.delete("product:#{id}")
  end
end
```

## Rate Limiting with Redis

Implement rate limiting:

```crystal
class RateLimiter
  def self.allowed?(key : String, limit : Int32, window : Time::Span) : Bool
    current = Azu.cache.increment("ratelimit:#{key}")

    if current == 1
      # Set expiration on first request
      Azu.cache.expire("ratelimit:#{key}", window)
    end

    current <= limit
  end
end

# Usage in endpoint
def call
  unless RateLimiter.allowed?(client_ip, limit: 100, window: 1.minute)
    raise Azu::Response::TooManyRequests.new
  end

  # Process request...
end
```

## Session Storage

Store sessions in Redis:

```crystal
class SessionStore
  def self.create(user_id : Int64) : String
    session_id = Random::Secure.hex(32)
    Azu.cache.set(
      "session:#{session_id}",
      {user_id: user_id, created_at: Time.utc}.to_json,
      expires_in: 24.hours
    )
    session_id
  end

  def self.get(session_id : String) : Int64?
    data = Azu.cache.get("session:#{session_id}")
    return nil unless data

    JSON.parse(data)["user_id"].as_i64
  end

  def self.destroy(session_id : String)
    Azu.cache.delete("session:#{session_id}")
  end
end
```

## Health Check

Verify Redis connectivity:

```crystal
struct HealthEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/health"

  def call
    redis_ok = begin
      Azu.cache.set("health_check", "ok", expires_in: 1.second)
      true
    rescue
      false
    end

    json({
      status: redis_ok ? "healthy" : "degraded",
      redis: redis_ok
    })
  end
end
```

## See Also

- [Set Up Memory Cache](setup-memory-cache.md)

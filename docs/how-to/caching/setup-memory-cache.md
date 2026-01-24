# How to Set Up Memory Cache

This guide shows you how to configure and use in-memory caching in Azu.

## Basic Setup

Configure the memory cache store:

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::MemoryStore.new
end
```

## Using the Cache

### Store and Retrieve Values

```crystal
# Store a value
Azu.cache.set("user:1", user.to_json)

# Retrieve a value
json = Azu.cache.get("user:1")
if json
  user = User.from_json(json)
end

# With expiration (TTL)
Azu.cache.set("session:abc123", session_data, expires_in: 30.minutes)
```

### Fetch Pattern

Use fetch to get or compute a value:

```crystal
user = Azu.cache.fetch("user:#{id}", expires_in: 1.hour) do
  User.find(id).to_json
end
```

### Delete Keys

```crystal
# Delete a single key
Azu.cache.delete("user:1")

# Delete multiple keys
["user:1", "user:2", "user:3"].each do |key|
  Azu.cache.delete(key)
end
```

### Check Existence

```crystal
if Azu.cache.exists?("user:1")
  # Key exists
end
```

### Clear All

```crystal
# Clear entire cache
Azu.cache.clear
```

## Caching in Endpoints

```crystal
struct UserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"]
    cache_key = "user:#{user_id}"

    cached = Azu.cache.get(cache_key)
    if cached
      return UserResponse.from_json(cached)
    end

    user = User.find(user_id.to_i64)
    response = UserResponse.new(user)

    Azu.cache.set(cache_key, response.to_json, expires_in: 10.minutes)

    response
  end
end
```

## Cache Configuration Options

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::MemoryStore.new(
    max_size: 10_000,           # Maximum number of entries
    default_ttl: 1.hour,        # Default expiration
    cleanup_interval: 5.minutes # How often to clean expired entries
  )
end
```

## Namespacing Keys

Organize cache keys with namespaces:

```crystal
module CacheKeys
  def self.user(id)
    "users:#{id}"
  end

  def self.user_posts(user_id)
    "users:#{user_id}:posts"
  end

  def self.post(id)
    "posts:#{id}"
  end
end

# Usage
Azu.cache.set(CacheKeys.user(user.id), user.to_json)
```

## Cache Invalidation

Invalidate related cache entries:

```crystal
class User
  include CQL::Model(User, Int64)

  after_save :invalidate_cache
  after_destroy :invalidate_cache

  private def invalidate_cache
    Azu.cache.delete("user:#{id}")
    Azu.cache.delete("user:#{id}:posts")
    Azu.cache.delete("users:list")
  end
end
```

## Thread Safety

The memory cache is thread-safe by default:

```crystal
# Safe to use from multiple fibers
spawn { Azu.cache.set("key1", "value1") }
spawn { Azu.cache.set("key2", "value2") }
spawn { Azu.cache.get("key1") }
```

## Cache Statistics

Monitor cache performance:

```crystal
stats = Azu.cache.stats
puts "Hits: #{stats.hits}"
puts "Misses: #{stats.misses}"
puts "Hit rate: #{stats.hit_rate}%"
puts "Size: #{stats.size} entries"
```

## When to Use Memory Cache

**Good for:**
- Single server deployments
- Session data
- Frequently accessed, rarely changed data
- Development and testing

**Consider Redis for:**
- Multi-server deployments
- Shared state across processes
- Persistence requirements
- Large cache sizes

## See Also

- [Set Up Redis Cache](setup-redis-cache.md)

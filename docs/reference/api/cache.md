# Cache Reference

The cache module provides flexible caching with multiple backend support.

## Cache Stores

### MemoryStore

In-process memory cache.

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::MemoryStore.new
end
```

**Options:**
- `max_size : Int32` - Maximum entries (default: 10000)
- `default_ttl : Time::Span` - Default expiration (default: 1.hour)

### RedisStore

Redis-backed distributed cache.

```crystal
Azu.configure do |config|
  config.cache = Azu::Cache::RedisStore.new(
    url: ENV["REDIS_URL"]
  )
end
```

**Options:**
- `url : String` - Redis connection URL
- `pool_size : Int32` - Connection pool size
- `namespace : String?` - Key prefix
- `default_ttl : Time::Span` - Default expiration

## Cache Methods

### set

Store a value.

```crystal
Azu.cache.set("key", "value")
Azu.cache.set("key", "value", expires_in: 1.hour)
```

**Parameters:**
- `key : String` - Cache key
- `value : String` - Value to store
- `expires_in : Time::Span?` - Optional TTL

### get

Retrieve a value.

```crystal
value = Azu.cache.get("key")  # => String?
```

**Parameters:**
- `key : String` - Cache key

**Returns:** `String?` - Cached value or nil

### fetch

Get or compute a value.

```crystal
value = Azu.cache.fetch("key", expires_in: 1.hour) do
  expensive_computation
end
```

**Parameters:**
- `key : String` - Cache key
- `expires_in : Time::Span?` - Optional TTL
- `&block` - Block to compute value if missing

**Returns:** `String` - Cached or computed value

### delete

Remove a value.

```crystal
Azu.cache.delete("key")
```

**Parameters:**
- `key : String` - Cache key

### exists?

Check if key exists.

```crystal
if Azu.cache.exists?("key")
  # Key is cached
end
```

**Parameters:**
- `key : String` - Cache key

**Returns:** `Bool`

### clear

Remove all cached values.

```crystal
Azu.cache.clear
```

### increment

Increment a numeric value.

```crystal
Azu.cache.increment("counter")        # => 1
Azu.cache.increment("counter")        # => 2
Azu.cache.increment("counter", by: 5) # => 7
```

**Parameters:**
- `key : String` - Cache key
- `by : Int32` - Increment amount (default: 1)

**Returns:** `Int32` - New value

### decrement

Decrement a numeric value.

```crystal
Azu.cache.decrement("counter")
Azu.cache.decrement("counter", by: 5)
```

**Parameters:**
- `key : String` - Cache key
- `by : Int32` - Decrement amount (default: 1)

**Returns:** `Int32` - New value

### expire

Set expiration on existing key.

```crystal
Azu.cache.expire("key", 30.minutes)
```

**Parameters:**
- `key : String` - Cache key
- `ttl : Time::Span` - Time to live

## RedisStore-Specific Methods

### delete_matched

Delete keys matching a pattern.

```crystal
Azu.cache.delete_matched("user:*")
```

**Parameters:**
- `pattern : String` - Glob pattern

### ttl

Get remaining time to live.

```crystal
remaining = Azu.cache.ttl("key")  # => Time::Span?
```

**Parameters:**
- `key : String` - Cache key

**Returns:** `Time::Span?` - Remaining TTL or nil

## Cache Patterns

### Cache-Aside

```crystal
def get_user(id : Int64) : User?
  cache_key = "user:#{id}"

  cached = Azu.cache.get(cache_key)
  return User.from_json(cached) if cached

  user = User.find?(id)
  if user
    Azu.cache.set(cache_key, user.to_json, expires_in: 15.minutes)
  end

  user
end
```

### Write-Through

```crystal
class User
  after_save :update_cache
  after_destroy :remove_from_cache

  private def update_cache
    Azu.cache.set("user:#{id}", to_json, expires_in: 1.hour)
  end

  private def remove_from_cache
    Azu.cache.delete("user:#{id}")
  end
end
```

### Cache Stampede Prevention

```crystal
def fetch_with_lock(key : String, expires_in : Time::Span, &)
  # Try cache first
  cached = Azu.cache.get(key)
  return cached if cached

  # Try to acquire lock
  lock_key = "lock:#{key}"
  if Azu.cache.set(lock_key, "1", expires_in: 10.seconds, nx: true)
    begin
      value = yield
      Azu.cache.set(key, value, expires_in: expires_in)
      value
    ensure
      Azu.cache.delete(lock_key)
    end
  else
    # Wait and retry
    sleep 100.milliseconds
    Azu.cache.get(key) || yield
  end
end
```

## Configuration Example

```crystal
Azu.configure do |config|
  if ENV["AZU_ENV"] == "production"
    config.cache = Azu::Cache::RedisStore.new(
      url: ENV["REDIS_URL"],
      pool_size: 10,
      namespace: "myapp:production",
      default_ttl: 1.hour
    )
  else
    config.cache = Azu::Cache::MemoryStore.new(
      max_size: 1000,
      default_ttl: 15.minutes
    )
  end
end
```

## See Also

- [How to Set Up Memory Cache](../../how-to/caching/setup-memory-cache.md)
- [How to Set Up Redis Cache](../../how-to/caching/setup-redis-cache.md)

# How to Set Up Redis Cache

This guide shows how to make `Azu.cache` use Redis, so several processes or servers share one cache that survives
restarts.

## Prerequisites

A running Redis. Azu depends on the `redis` shard (`stefanwille/crystal-redis ~> 2.9.0`) itself, so `shards install`
already fetched it; your app does not list it again.

## Basic Setup

Select the store and the URL before the first use of `Azu.cache`:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.cache_config.store = "redis"
    config.cache_config.redis_url = ENV.fetch("CACHE_REDIS_URL", "redis://localhost:6379/0")
  end
end
```

The same settings can come from the environment, with no code: `CACHE_STORE=redis` and
`CACHE_REDIS_URL=redis://localhost:6379/0`. There is **no default** URL and `REDIS_URL` is not read, because it often
names a Redis used for something else: `store = "redis"` without `CACHE_REDIS_URL`, `cache_config.redis_url` or a
`redis_client` raises an `ArgumentError` when the cache is built. To use localhost, say so in the URL. There is no
`config.cache = RedisStore.new(...)`. To put the cache on the same connections as PubSub and Presence, share one
[`Azu::Redis::Client`](../../reference/api/redis.md) with `config.cache_config.redis_client = client`.

## What Happens When Redis Is Unreachable

When the manager is built it pings Redis. If the ping fails, it retries `cache_connection_retries` times (3), waiting
`cache_connection_retry_delay` seconds (1) and doubling the wait after each attempt. If every attempt fails, the
error is logged and **the cache is disabled**: `Azu.cache` becomes a `NullStore`, `set` returns `false`, `get`
returns `nil` and `fetch` runs its block every time. The application keeps serving and never raises because
Redis is down. Against a closed port the first use of `Azu.cache` took 3.0 seconds (1 s + 2 s of waiting between the
three attempts), logged the failure, and every call afterwards behaved as an always-missing cache. Restart the
process after Redis is back to use it again.

A `RedisStore` built directly, or a command that fails after start-up, is logged and swallowed the same way: `get`
returns `nil`, `set` and `delete` return `false`.

## Using the Redis Cache

The API is the same as for the memory cache; see the [cache reference](../../reference/api/cache.md).

### Store and Retrieve Values

```crystal
require "azu"
require "json"

Azu.cache.set("user:1", {id: 1, name: "Ada"}.to_json)

# with a time to live
Azu.cache.set("session:abc", "data", 30.minutes)

data = Azu.cache.get("user:1")
```

`Azu.cache` prefixes every key with `key_prefix` (`azu:` by default), so `"user:1"` is meant to be stored as
`azu:user:1`. A TTL is stored with `SETEX` in whole seconds (a 30 minute TTL read back from Redis as 1799 seconds).
Without one, `cache_config.default_ttl` (an hour) applies.

### Fetch Pattern

```crystal
require "azu"

user_json = Azu.cache.fetch("user:1", 1.hour) do
  %({"id":1,"name":"Ada"})
end
```

### Delete Keys

```crystal
require "azu"

Azu.cache.delete("user:1")
```

There is no pattern deletion (`delete_matched`). To drop a group of keys, delete the known keys, use a version in the
key name, or remove them from `redis-cli` with `--scan --pattern`.

### Increment and Decrement

```crystal
require "azu"

Azu.cache.increment("page_views:home")    # => 1, then 2, ...
Azu.cache.increment("api_calls:user:1", 1, 1.minute)
Azu.cache.decrement("available_slots")
```

`increment(key, amount = 1, ttl = nil)` returns the new value, or `nil` if Redis failed. The TTL is set once, when
the counter is created, and later hits do not renew it. It is not retried after a lost connection: it may already
have been applied.

## Connection Pool and Timeouts

```crystal
require "azu"

Azu::CONFIG.cache_config.redis_pool_size = 10        # connections
Azu::CONFIG.cache_config.redis_timeout = 5           # seconds to wait for a free connection
Azu::CONFIG.cache_config.redis_operation_timeout = 2 # seconds per command
```

The same settings come from `CACHE_REDIS_POOL_SIZE`, `CACHE_REDIS_TIMEOUT` and `CACHE_REDIS_OPERATION_TIMEOUT`.

## A Store of Your Own

`Azu::Cache::RedisStore` can be created directly, for example for a second Redis that does not go through
`Azu.cache`:

```crystal
require "azu"

store = Azu::Cache::RedisStore.new(
  "redis://localhost:6379/1",
  pool_size: 10,
  timeout: 5.seconds,
  default_ttl: 1.hour,
  operation_timeout: 2.seconds,
)

store.set("key", "value", 5.minutes)
puts store.get("key")
```

The store runs on the shared [`Azu::Redis`](../../reference/api/redis.md) pool: `Azu::Cache::RedisStore.new(client)`
takes a client you built with `Azu::Redis.acquire`, so the cache, PubSub and Presence can use the same connections.
`operation_timeout` is the bound on every command (a command past it fails like any other and its connection is
thrown away), and a lost connection is replaced and the command tried again once (not for `increment`).

The store has no key prefix; the `Cache::Manager` adds it. A password or TLS goes in the URL
(`rediss://:password@host:6380/0`). There is no `namespace:`, `ssl:` or `password:` option.

## Key Prefixes

Separate applications or environments that share a Redis with `key_prefix` (`CACHE_KEY_PREFIX`):

```crystal
require "azu"

Azu::CONFIG.cache_config.key_prefix = "myapp:production"
```

`Azu.cache.clear` removes only the keys that start with `"<key_prefix>:"` (a `SCAN` and `UNLINK` in batches), so other
keys in the same Redis database survive. `Azu.cache.clear(all: true)` runs `FLUSHDB` and removes **every** key of
the database: use a database only the cache uses if you call it.

## Caching Complex Objects

```crystal
require "azu"
require "json"

struct UserSummary
  include JSON::Serializable

  getter id : Int64
  getter name : String
  getter post_titles : Array(String)

  def initialize(@id, @name, @post_titles)
  end
end

def cache_user_summary(summary : UserSummary) : Nil
  Azu.cache.set("user:#{summary.id}:summary", summary.to_json, 15.minutes)
end

def cached_user_summary(id : Int64) : UserSummary?
  Azu.cache.get("user:#{id}:summary").try { |json| UserSummary.from_json(json) }
end
```

## Cache-Aside in an Endpoint

```crystal
require "azu"

struct ProductPage
  include Azu::Response

  def initialize(@json : String)
  end

  def render
    @json
  end
end

struct ProductEndpoint
  include Azu::Endpoint(Azu::Request, ProductPage)

  get "/products/:id"

  def call : ProductPage
    content_type "application/json"
    id = params["id"]

    json = Azu.cache.fetch("product:#{id}", 1.hour) do
      {id: id, name: "Product #{id}"}.to_json
    end

    ProductPage.new(json)
  end
end
```

## Invalidate on Write

Delete the key in the code that changes the data:

```crystal
require "azu"

def update_product(id : Int64, name : String) : Nil
  # ... update the database ...
  Azu.cache.delete("product:#{id}")
end
```

## Rate Limiting

Use `Azu::Handler::Throttle` for per-client request limits; it keeps its counters in process and needs no cache.

## Session Storage

```crystal
require "azu"
require "json"

module SessionStore
  def self.create(user_id : Int64) : String
    session_id = Random::Secure.hex(32)
    Azu.cache.set("session:#{session_id}", {user_id: user_id}.to_json, 24.hours)
    session_id
  end

  def self.user_id(session_id : String) : Int64?
    Azu.cache.get("session:#{session_id}").try { |json| JSON.parse(json)["user_id"].as_i64 }
  end

  def self.destroy(session_id : String) : Nil
    Azu.cache.delete("session:#{session_id}")
  end
end
```

## Health Check

`Azu.cache.ping` returns `"PONG"` when Redis answers and `nil` otherwise (and for any other store). Hand it to the
health handler:

```crystal
require "azu"

health = Azu::Handler::HealthCheck.new(
  checks: {"redis" => -> { Azu.cache.ping == "PONG" }} of String => Azu::Handler::HealthCheck::Check
)
```

Use it in the handler array of `start`; `/health` answers `200`, or `503 {"status":"unavailable","failing":["redis"]}`.
`Azu.cache.redis_info` returns the parsed `INFO` of the server.

## What Was Checked

The store is exercised against a live Redis 7 by `spec/azu/cache_spec.cr` (reads, counters with their TTL, multi-key
operations, pooling, the operation timeout) and `spec/azu/redis_spec.cr`; both go pending without a server.

## See Also

- [Set Up Memory Cache](setup-memory-cache.md)
- [Cache reference](../../reference/api/cache.md)

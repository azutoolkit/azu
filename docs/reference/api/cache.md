---
description: "The application cache: string values under keys, with a TTL, in memory or in Redis."
---

# Cache

`Azu.cache` is the application's cache: an `Azu::Cache::Manager` that stores strings under keys, with a TTL, in
memory (the default) or in Redis. It comes with `require "azu"`. Values are strings; serialize richer data yourself
(`to_json` / `from_json`). It is not a session store or a job queue, and it has no tags or dependency tracking.

```crystal
require "azu"

Azu.cache.set("greeting", "hello", ttl: 5.minutes)
puts Azu.cache.get("greeting")                     # => hello
puts Azu.cache.fetch("answer", 1.hour) { "42" }    # computed once, then cached
```

`Azu.cache` is `Azu.current_config.cache`, so inside a request it is the cache of the app serving it.

## Options

The manager is built on first use from `config.cache_config`, so configure it before the first call. All options and
their environment variables are in the [configuration reference](../configuration/options.md#cache).

```crystal
require "azu"

Azu::CONFIG.cache_config.store = "memory"   # "memory" (default), "redis" or "null"
Azu::CONFIG.cache_config.max_size = 5_000    # entries (memory store)
Azu::CONFIG.cache_config.default_ttl = 900   # seconds, for calls that pass no TTL
Azu::CONFIG.cache_config.key_prefix = "myapp"
```

A manager of your own, independent of the app, takes a `Cache::Configuration`:

```crystal
require "azu"

config = Azu::Cache::Configuration.new
config.max_size = 100
cache = Azu::Cache::Manager.new(config)
cache.set("a", "1")
```

Keys are stored as `<key_prefix>:<key>` (`azu:` by default). With `enabled = false` (or `CACHE_ENABLED=false`) the
manager uses a `NullStore`: `set` returns `false`, `get` returns `nil`, and `fetch` runs its block every time.
An unknown `store` name raises `ArgumentError: Unsupported cache store: ...`.

## API

### Stores

{% tabs %}
{% tab title="MemoryStore" %}
In-process, thread-safe, least-recently-used eviction, entries expire by TTL.

```crystal
require "azu"

store = Azu::Cache::MemoryStore.new(max_size: 2, default_ttl: 1.minute, cleanup_interval: 1.minute)
store.set("a", "1")
store.set("b", "2")
store.get("a")
store.set("c", "3")        # evicts "b", the least recently used
puts store.get("b").inspect # => nil
puts store.size             # => 2
```

- `max_size : Int32` - maximum entries (default 1000).
- `default_ttl : Time::Span?` - used when `set` is given none (default 1 hour).
- `cleanup_interval : Time::Span` - how often a background fiber drops expired entries (default 5 minutes).
  Expired entries are also never returned, whatever the interval.

`stats` returns `size`, `max_size`, `memory_usage_mb` and `hit_rate`; `hit_rate` is the share of `get` lookups
that found a live entry (`hits / (hits + misses) * 100`, 0.0 before the first lookup). An expired entry counts as
a miss, and `exists?` is not counted.
{% endtab %}

{% tab title="RedisStore" %}
Distributed, backed by the `redis` shard (a dependency of Azu) through the shared [`Azu::Redis`](redis.md) pool.
`RedisStore.new(client)` takes an `Azu::Redis::Client` to share connections with PubSub and Presence.

```crystal
require "azu"

store = Azu::Cache::RedisStore.new(
  "redis://localhost:6379/0",
  pool_size: 10,
  timeout: 5.seconds,
  default_ttl: 1.hour,
  operation_timeout: 2.seconds,
)
```

A failing command is logged and swallowed: `get` returns `nil`, `set` / `delete` return `false`, `increment`
returns `nil`. Through `Azu::CONFIG` use `cache_config.store = "redis"` and `cache_config.redis_url`. If the first
connection check fails `cache_connection_retries` times (waiting `cache_connection_retry_delay` seconds, doubling
each time, so 3 seconds of waiting with the defaults), the manager logs the failure and falls back to a disabled
`NullStore`. Everything then behaves as a cache that never hits.
{% endtab %}

{% tab title="NullStore" %}
Stores nothing. Used when caching is disabled or Redis is unavailable at startup.
{% endtab %}
{% endtabs %}

### Methods of `Azu.cache`

On a disabled cache every method does nothing and returns `nil`, `false`, `0` or an empty hash. TTLs are `Time::Span`s; when none is
given, `cache_config.default_ttl` seconds apply.

### set

```crystal
require "azu"

Azu.cache.set("key", "value")                 # => true
Azu.cache.set("key", "value", 30.minutes)
Azu.cache.set("key", "value", ttl: 30.minutes)
```

`set(key : String, value : String, ttl : Time::Span? = nil) : Bool`. A replaced value gets a fresh TTL.

### get

```crystal
require "azu"

value = Azu.cache.get("key") # => String?
```

`get(key : String) : String?`: `nil` when missing or expired.

### fetch

```crystal
require "azu"

page = Azu.cache.fetch("home", 10.minutes) do
  "<h1>rendered once</h1>"
end
```

`fetch(key, ttl = nil, &block : -> String) : String` returns the cached value, or computes it, stores it and returns
it. Concurrent fibers asking for the same missing key wait for one computation (a lock per key), so the block runs
once for all of them. `get(key, ttl) { ... }` with a block is the same operation.

### delete, exists?, clear, size

```crystal
require "azu"

Azu.cache.delete("key")  # => Bool, true when the key existed
Azu.cache.exists?("key") # => Bool
Azu.cache.size           # => Int32
Azu.cache.clear          # removes the cache's entries (the keys under key_prefix)
Azu.cache.clear(all: true) # empties the whole store
```

On Redis, `clear` scans for the keys that start with `"<key_prefix>:"` and `UNLINK`s them in batches; every other
key of the database stays.

{% hint style="danger" %}
`clear(all: true)` is `FLUSHDB` on the selected database; `RedisStore#clear` (the store used directly, which has no
prefix) is `FLUSHDB` too.
{% endhint %}

With `store = "redis"` and no URL the cache refuses to build
(`ArgumentError` naming `CACHE_REDIS_URL`): there is no default Redis, and `Azu.cache` does not swallow that error
into a disabled cache (an unreachable Redis still does); `start` checks it too, without connecting.

{% hint style="warning" %}
The prefix `clear` walks the whole keyspace (`SCAN`, so it costs O(keys in the database)), is not atomic (`false`
means some keys may be gone), needs Redis 4.0 (`UNLINK`) and does not support Redis Cluster (`SCAN` visits one node,
`UNLINK` across slots fails).
{% endhint %}

### get_multi, set_multi

```crystal
require "azu"

Azu.cache.set_multi({"a" => "1", "b" => "2"}, 5.minutes)
Azu.cache.get_multi(["a", "b", "c"]) # => {"a" => "1", "b" => "2", "c" => nil}
```

### increment, decrement

```crystal
require "azu"

Azu.cache.increment("hits")      # => 1
Azu.cache.increment("hits")      # => 2
Azu.cache.increment("hits", 5)   # => 7
Azu.cache.decrement("hits")      # => 6
```

`increment(key, amount = 1, ttl = nil) : Int32?`. The amount is positional (there is no `by:`). The TTL is set
when the counter is created; later calls do not renew it. For rate limiting use `Azu::Handler::Throttle`, which does
not use the cache.

### stats, ping, redis_info

`stats` returns `enabled`, `store_type`, `size` and, for the memory store, the memory store's own statistics.
`ping` and `redis_info` talk to Redis and return `nil` for any other store.

## Behavior

### Cache-aside

Cache a serialized value, and rebuild it on a miss:

```crystal
require "azu"
require "json"

struct Product
  include JSON::Serializable

  getter id : Int64
  getter name : String

  def initialize(@id, @name)
  end
end

def load_product(id : Int64) : Product
  Product.new(id, "Product #{id}")
end

def product(id : Int64) : Product
  json = Azu.cache.fetch("product:#{id}", 15.minutes) { load_product(id).to_json }
  Product.from_json(json)
end
```

### Invalidate on write

Delete (or overwrite) the key where the data changes:

```crystal
require "azu"
require "json"

def update_product_name(id : Int64, name : String) : Nil
  # ... write to the database first ...
  Azu.cache.delete("product:#{id}")
  Azu.cache.delete("products:list")
end
```

### Stampede prevention

`fetch` already serializes computation per key within a process. The lock is not shared between processes: with
several processes (even on a Redis store) each may compute a missing value once.

### Observing the cache

Every operation is reported to `Azu::Instrumentation.on_cache` subscribers; see [Instrumentation](instrumentation.md).

## Limits

- There is no `expire`, `ttl`, `delete_matched` or compare-and-set (`nx:`) operation.
- The `fetch` lock is per process (see [Stampede prevention](#stampede-prevention)).

## See also

- [Set up memory cache](../../how-to/caching/setup-memory-cache.md)
- [Set up Redis cache](../../how-to/caching/setup-redis-cache.md)
- [Configuration options](../configuration/options.md#cache)
- [Instrumentation](instrumentation.md)

# Set up a memory cache

The memory store is the default: with no configuration `Azu.cache` already stores up to 1000 entries for an hour
each, evicting the least recently used. It lives in the memory of one process, so each process of a deployment has
its own copy (use [Redis](setup-redis-cache.md) to share).

## Basic Setup

Set the options before the first use of `Azu.cache`; the store is built on first use and later changes do not
rebuild it:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.cache_config.store = "memory"
    config.cache_config.max_size = 10_000        # entries
    config.cache_config.default_ttl = 3600       # seconds
    config.cache_config.cache_cleanup_interval = 300 # seconds
    config.cache_config.key_prefix = "myapp"
  end
end
```

The same options come from the environment: `CACHE_STORE`, `CACHE_MAX_SIZE`, `CACHE_DEFAULT_TTL`,
`CACHE_CLEANUP_INTERVAL`, `CACHE_KEY_PREFIX`. There is no `config.cache = MemoryStore.new(...)`.

## Using the Cache

### Store and Retrieve Values

Values are strings. Serialize objects yourself:

```crystal
require "azu"
require "json"

Azu.cache.set("user:1", {id: 1, name: "Ada"}.to_json)

if json = Azu.cache.get("user:1")
  user = JSON.parse(json)
  puts user["name"]
end

# with a time to live
Azu.cache.set("session:abc123", "data", 30.minutes)
```

An entry that has outlived its TTL is never returned, even before the background cleanup removes it.

### Fetch Pattern

`fetch` returns the cached value, or runs the block, stores its result and returns it:

```crystal
require "azu"

report = Azu.cache.fetch("report:daily", 1.hour) do
  "expensive report"
end
puts report
```

Two fibers asking for the same missing key at the same moment compute it once; the second waits for the first.

### Delete Keys

```crystal
require "azu"

Azu.cache.delete("user:1")

["user:1", "user:2", "user:3"].each { |key| Azu.cache.delete(key) }
```

There is no pattern deletion. To invalidate a group of keys, delete each key you know, or put a version in the
key (`"users:v#{version}:list"`) and bump it.

### Check Existence

```crystal
require "azu"

if Azu.cache.exists?("user:1")
  puts "cached"
end
```

### Clear All

```crystal
require "azu"

Azu.cache.clear
```

## Caching in Endpoints

Cache the rendered body of an expensive endpoint and answer from it:

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

    json = Azu.cache.fetch("product:#{id}", 10.minutes) do
      {id: id, name: "Product #{id}", loaded_at: Time.utc.to_rfc3339}.to_json
    end

    ProductPage.new(json)
  end
end
```

Within the ten minutes, a second request for `/products/7` gets the same `loaded_at` (the block runs once per
key), and `/products/8` computes its own entry.

## How Eviction Works

When the store holds `max_size` entries and a new key arrives, the entry that was read or written longest ago is
removed. Reading a key counts as using it:

```crystal
require "azu"

store = Azu::Cache::MemoryStore.new(max_size: 3, default_ttl: 1.hour, cleanup_interval: 1.minute)
store.set("a", "1")
store.set("b", "2")
store.set("c", "3")
store.get("a")      # "a" is now the most recently used
store.set("d", "4") # evicts "b"
puts store.get("b").inspect # => nil
puts store.get("a")         # => 1
```

## Cache Invalidation

Invalidate where the data changes. Azu has no model callbacks of its own, so do it in the code that writes
(a service, an endpoint, or your ORM's callbacks):

```crystal
require "azu"

def rename_user(id : Int64, name : String) : Nil
  # ... update the database ...
  Azu.cache.delete("users:#{id}")
  Azu.cache.delete("users:#{id}:posts")
end
```

## Thread Safety

The store is protected by a mutex, so any number of fibers can use `Azu.cache` at the same time.

## Observing the Cache

`stats` reports the size of the store and its hit rate:

```crystal
require "azu"

stats = Azu.cache.stats
puts stats["size"]      # entries
puts stats["max_size"]  # limit
puts stats["hit_rate"]  # percent of lookups that found an entry
```

`hit_rate` is the memory store's hits divided by its lookups, times 100, counted since the store was created (`0.0`
before the first lookup; `clear` does not reset it): three hits and one miss give `75.0`. To count hits and misses yourself, for example per
key, subscribe to the cache operations:

```crystal
require "azu"

hits = Atomic(Int32).new(0)
misses = Atomic(Int32).new(0)

Azu::Instrumentation.on_cache do |operation|
  next unless operation.operation == "get"
  (operation.hit ? hits : misses).add(1)
end
```

## When to Use the Memory Cache

**Good for:**
- A single process or a single server
- Data that is cheap to rebuild on a restart
- Development and tests

**Consider Redis for:**
- Several processes or servers that must see the same cache
- A cache that survives restarts
- More entries than one process should hold

## See Also

- [Set Up Redis Cache](setup-redis-cache.md)
- [Cache reference](../../reference/api/cache.md)

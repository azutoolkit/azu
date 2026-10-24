# Redis

`Azu::Redis` is the one place Azu opens connections to Redis. The cache (`Cache::RedisStore`), the PubSub backend
(`PubSub::Redis`) and Presence (`Presence::Store::Redis`) all go through an `Azu::Redis::Client`, so they share a
pool, a URL, timeouts, a retry policy and a shutdown, instead of each opening its own connections with its own
settings. It is a small layer over the `redis` shard (`stefanwille/crystal-redis ~> 2.9.0`, a dependency of Azu);
nothing connects at require time or when a client is built, only on first use.

## Config

`Azu::Redis::Config` is one value holding every setting:

| Setting | Default | Meaning |
| --- | --- | --- |
| `url` | `redis://localhost:6379/0` | `redis://` or `rediss://` (TLS), optional `:password@` and `/db` |
| `pool_size` | 5 | Most connections the pool opens |
| `checkout_timeout` | 5 s | How long a fiber waits for a free connection (`Redis::PoolTimeoutError`) |
| `connect_timeout` | 5 s | Bound on opening a connection |
| `command_timeout` | 5 s | Bound on every read and write of a connection (the shard has one setting for both) |
| `health_check_after` | 30 s | A connection idle this long is probed with `PING` before it is reused |
| `retry` | `Retry.new` (1 retry) | See [Retries](#retries) |
| `tls_ca_file`, `tls_verify` | `nil`, `true` | CA bundle for `rediss://`; `tls_verify: false` turns peer verification off |
| `name` | `"azu"` | Shown in `CLIENT LIST` (`name=azu-<name>`) |
| `prefix` | `""` | Used by `Client#key` |

```crystal
require "azu"

config = Azu::Redis::Config.new("rediss://:s3cret@redis.internal:6380/2", pool_size: 10, command_timeout: 2.seconds)
config.redacted_url # => "rediss://:***@redis.internal:6380/2"
```

`inspect` and `to_s` of a config and of a client show the URL with its password replaced by `***`.

`Azu::Redis::Config.from_env` is the one place the Redis variables are read:

| Variable | Setting |
| --- | --- |
| `REDIS_URL` | `url` |
| `REDIS_POOL_SIZE` | `pool_size` |
| `REDIS_POOL_TIMEOUT`, `REDIS_CONNECT_TIMEOUT`, `REDIS_TIMEOUT` | `checkout_timeout`, `connect_timeout`, `command_timeout` (seconds, fractions allowed) |
| `REDIS_RETRIES` | `retry.retries` |
| `REDIS_TLS_CA_FILE`, `REDIS_TLS_VERIFY` | `tls_ca_file`, `tls_verify` (`false`, `0`, `no`, `off` disable verification) |
| `REDIS_PREFIX` | `prefix` |

A malformed number raises an `ArgumentError` that names the variable and not its value. The subsystems add their own
URL variable in front of `REDIS_URL`: `PUBSUB_REDIS_URL` for PubSub, and `PRESENCE_REDIS_URL`, then
`PUBSUB_REDIS_URL`, for Presence. With none of them set, `REDIS_URL` is used, then
`redis://localhost:6379/0`.

> **The cache never reads `REDIS_URL`.** `Cache#clear` is `FLUSHDB`, and `REDIS_URL` often names the Redis of
> sessions or a job queue. The cache needs `CACHE_REDIS_URL` or `cache_config.redis_url` (or a client you hand it).


## Sharing one pool

```crystal
require "azu"

redis = Azu::Redis.acquire(Azu::Redis::Config.from_env)

Azu::Cache::RedisStore.new(redis)
Azu::PubSub.backend = Azu::PubSub::Redis.new(redis)
Azu::Presence.default = Azu::Presence::Tracker.new(Azu::Presence::Store::Redis.new(redis))
```

`Azu::Redis.acquire(config)` returns a handle on the pool for those settings: another `acquire` with the same
connection settings (`url`, `pool_size`, the three timeouts, `health_check_after` and TLS; not `name`, `prefix` or
`retry`, which belong to the handle) gets a handle on the same pool. The pool closes with its last handle, or on
`Azu::Redis.shutdown`.

The URL constructors do the same for you: `PubSub::Redis.new(url)` and `Store::Redis.new(url)` acquire a client for
the URL (a pool of 2, 5 second connect and command timeouts), so the two share a pool when they use the same URL.
`Cache::RedisStore.new(url, pool_size, timeout, ttl, operation_timeout)` keeps its signature and uses
`operation_timeout` as its command timeout, so with the default 2 seconds it has a pool of its own; pass the shared
client (`Cache::RedisStore.new(redis)` or `cache_config.redis_client = redis`) to put the cache on the same pool.
A client you pass is yours to close; one a backend or store built from a URL is closed by its `shutdown` or `close`.

## Using a client

```crystal
require "azu"

redis = Azu::Redis::Client.new(Azu::Redis::Config.new)

redis.run { |connection| connection.set("greeting", "hello") }
redis.run("get") { |connection| connection.get("greeting") } # => "hello"

redis.multi do |transaction|
  transaction.command(["HSET", "counts", "a", "1"])
  transaction.command(["EXPIRE", "counts", "60"])
end

redis.pipelined do |pipeline|
  pipeline.command(["INCR", "hits"])
  pipeline.command(["INCR", "hits"])
end

redis.time   # the server's clock (TIME)
redis.ping   # => true; false instead of raising
redis.key("sessions:1") # => "<prefix>sessions:1"
redis.close
```

- `run(operation = "command", retry: true) { |connection| ... }` borrows a pooled connection. The block runs again
  on a fresh connection if the first one was dead, so it should not have effects other than Redis commands.
- `multi` and `pipelined` take the shard's transaction and pipeline objects and return the array of replies.
- `with_prefix(prefix)` returns a view with another `key` prefix on the same pool; closing a view does nothing.
- `time` reads `TIME`, so nodes that write and judge expiry (Presence) need no synchronized clocks.
- `stats` returns `capacity`, `open`, `in_use`, `idle`, `discarded` (connections thrown away after an error) and
  `adopted` (dedicated connections).

### Pool behaviour

- Connections are opened lazily and reused before another is opened, so a quiet app holds one.
- A connection whose use failed with a connection error, a timeout or a TLS failure is closed and replaced; one
  that only saw a server error reply (`WRONGTYPE`) is kept.
- A connection idle for `health_check_after` is probed with `PING` on checkout and replaced if it fails.
- A waiter is woken when a connection is discarded, because that frees room to open a new one.
- Closing the pool closes idle connections at once and checked out ones as they return; fibers still waiting fail
  with `Azu::Redis::ClosedError`.

### Retries

`Azu::Redis::Retry.new(retries: 1, base: 10.milliseconds, max: 1.second, jitter: 0.5)`: after a lost or refused
connection a command is tried again up to `retries` times, waiting `base * 2^attempt` (at most `max`, shortened by
up to `jitter` of itself) before each. The wait goes through `Azu::Clock.sleep`, so a spec with
`Azu::Clock::Fake` retries without sleeping. `Retry.none` turns retries off, and `run(retry: false)` does so for
one call (the cache does this for `increment`, which must not be applied twice).

A command that **timed out** is not retried, since it may have been applied; its connection is discarded because a
late reply would answer the next command. A server error reply and a pool timeout are not retried either.

### Dedicated connections

```crystal
require "azu"

redis = Azu::Redis::Client.new(Azu::Redis::Config.new)
subscriber = redis.dedicated
spawn { subscriber.subscribe("news") { |on| on.message { |channel, message| puts message } } }
# ...
redis.release(subscriber)
```

`dedicated` opens a connection that is not taken from the pool and has no read timeout, for something that holds
it for good, such as a `SUBSCRIBE` loop (`PubSub::Redis` uses one). It does not count against `pool_size` and ends
with the client or with `release`.

## Health check

`Client#health_check` is a `Proc(Bool)` for `Azu::Handler::HealthCheck`:

```crystal
require "azu"

redis = Azu::Redis.acquire
checks = {"redis" => redis.health_check} of String => Azu::Handler::HealthCheck::Check
Azu::Handler::HealthCheck.new(checks: checks)
```

## Instrumentation

`Azu::Instrumentation.on_redis { |command| ... }` receives an `Instrumentation::RedisCommand` (`operation`,
`client` name, `duration_ms`, `error`) for each finished `run`, `multi` and `pipelined`. With no subscriber a call
costs a nil check.

## Shutdown

`Azu.shutdown` stops Spark, then Presence, then PubSub, and last calls `Azu::Redis.shutdown`, which closes every
shared pool. The order matters: Presence's departures are published through PubSub, which needs the pool. A closed
client raises `Azu::Redis::ClosedError`.

## Not part of the contract

- Connections are not multiplexed: one command at a time per connection, `pool_size` at most at once.
- There is no cluster or sentinel support; the shard has none.
- `Clock.sleep` is used for backoff only; the pool's checkout timeout is real time.

## See also

- [Cache](cache.md), [Presence](presence.md), [Scale out real-time](../../how-to/deployment/scale-out-realtime.md)

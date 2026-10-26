---
description: "Subscribe to cache operations, Redis calls and Spark component steps, and hook into an app's start, through `Azu::Instrumentation`."
---

# Instrumentation

`Azu::Instrumentation` is the seam between Azu's core and the code that measures it: `require "azu/dev"` (the
development dashboard and performance monitor) plugs in here, and so can a metrics or tracing library of your own.
Core reports finished cache operations, Redis calls and Spark component steps, and announces when a configuration is
prepared and collected. It comes with `require "azu"`. With no subscriber, each report costs a nil check. It does not
report requests or SQL: request timing is a handler's job, and SQL goes to `Azu::QueryStore` through `azu/cql`.

```crystal
require "azu"

Azu::Instrumentation.on_cache do |operation|
  if operation.operation == "get" && operation.hit == false
    Log.for("cache").debug { "miss #{operation.key} (#{operation.duration_ms.round(3)} ms)" }
  end
end
```

## API

| Method | Notes |
| --- | --- |
| `on_cache(enabled : Proc(Bool) = -> { true }, &block : CacheOperation ->)` | Called after each operation of an `Azu::Cache::Manager` (`Azu.cache`) |
| `on_redis(enabled : Proc(Bool) = -> { true }, &block : RedisCommand ->)` | Called after each `run`, `multi` and `pipelined` of an `Azu::Redis::Client` |
| `on_component(enabled : Proc(Bool) = -> { true }, &block : ComponentEvent ->)` | Called after each lifecycle step of a Spark component |
| `on_prepare(&hook : Configuration ->)` | Runs when `Configuration#prepare` starts what an app needs (`App#start` calls it) |
| `on_finalize(&hook : Configuration ->)` | Runs when a `Configuration` is garbage collected |
| `prepare(config : Configuration)` | Runs the `on_prepare` hooks; `Configuration#prepare` calls it |
| `finalize(config : Configuration)` | Runs the `on_finalize` hooks; `Configuration#finalize` calls it |
| `isolate(&)` | Runs the block with no subscribers and no hooks, then restores the previous ones; for specs |

`enabled` is asked before each operation. While every subscriber of a kind answers `false`, the operation is not
timed or reported; a subscriber whose `enabled` answers `false` is skipped. The subscribers of `azu/dev` are
enabled only while the current configuration's `performance_enabled?` is on, so they cost nothing while monitoring
is off.

### Events

`Instrumentation::CacheOperation`:

| Field | Type | Value |
| --- | --- | --- |
| `key` | `String` | The key as the caller gave it, without `key_prefix`; `"all"` for `clear` |
| `operation` | `String` | `get` (also for `fetch`'s lookup), `set`, `delete`, `exists`, `increment`, `decrement`, `clear` |
| `store` | `String` | `cache_config.store`: `memory`, `redis` or `null` |
| `key_size` | `Int32` | Bytes of the key |
| `value_size` | `Int32?` | Bytes written, for `set` |
| `ttl` | `Time::Span?` | For `set`, the TTL applied (`default_ttl` when the caller gave none); for `increment` and `decrement`, the one passed |
| `duration_ms` | `Float64` | Time the store took |
| `hit` | `Bool?` | For `get` only: whether a value was found |
| `error` | `String?` | The message of the exception the operation raised |

`Instrumentation::RedisCommand`:

| Field | Type | Value |
| --- | --- | --- |
| `operation` | `String` | The caller's label: `get`, `setex`, `publish`, `presence`, ...; `command`, `multi` and `pipeline` by default |
| `client` | `String` | `Azu::Redis::Config#name` of the client |
| `duration_ms` | `Float64` | Including retries |
| `error` | `String?` | The message of the exception the call ended with |

`Instrumentation::ComponentEvent`:

| Field | Type | Value |
| --- | --- | --- |
| `id` | `String` | The component's id |
| `type` | `String` | The component's class name |
| `event` | `String` | `mount`, `unmount`, `refresh` (a render) or `event_handler:<name>` |
| `age` | `Time::Span` | Time since the component was mounted |
| `duration_ms` | `Float64` | Time the step took |
| `memory_before`, `memory_after` | `Int64` | GC heap size in bytes before and after the step |

## Behavior

- Cache and Redis events are reported also when the operation raises, with `error` set, and the exception still
  reaches the caller. A component step that raises is not reported.
- A subscriber, `enabled` check or hook that raises is logged at debug level (`azu.instrumentation`) and never breaks
  the operation it observes.
- Subscribers run in the fiber of the operation, after it finished: a slow subscriber slows the caller.
- `get_multi`, `set_multi`, `size` and `stats` of the cache are not reported, and neither is anything a disabled
  cache (`cache_config.enabled = false`) is asked.

## Limits

- Register subscribers and hooks once, at boot (when your code is required). They are read without a lock, so
  registering while operations run is not supported, and there is no way to remove one but `isolate`.
- Subscribers are process-wide: they see the operations of every `Azu::App` in the process.

## See also

- [Cache](cache.md)
- [Redis](redis.md)
- [Performance design](../../explanation/architecture/performance-design.md)

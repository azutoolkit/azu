---
description: "The time source behind every TTL, window and token lifetime in Azu, and the fake clock that lets a spec move time instead of sleeping."
---

# Clock

`Azu::Clock` is where Azu reads the time for everything that expires: cache entries, throttle windows, CSRF and
Spark token lifetimes, Presence leases. It comes with `require "azu"` and reads the system clock. A spec installs a
`Clock::Fake` and advances it, so a ten-minute TTL is tested without waiting ten minutes. It is a seam for specs,
not a scheduler: it does not wake anything up when time moves.

```crystal
require "azu"

store = Azu::Cache::MemoryStore.new

Azu::Clock.use(Azu::Clock::Fake.new) do |clock|
  store.set("greeting", "hello", 1.minute)
  clock.as(Azu::Clock::Fake).advance(61.seconds)
  store.get("greeting") # => nil
end
```

## API

| Method | Returns | Notes |
| --- | --- | --- |
| `Clock.now` | `Time` | Wall-clock time (UTC from the system source). For values that are serialized: token expiry, timestamps |
| `Clock.instant` | `Time::Instant` | Monotonic time. For anything that measures elapsed time: TTLs, windows |
| `Clock.coarse_nanoseconds` | `Int64` | A monotonic reading that may lag `instant` by one timer tick (1 to 10 ms) and is cheaper to read; compare it only with other readings of itself |
| `Clock.sleep(span : Time::Span)` | `Nil` | Waits on the system source; a fake one advances by *span* and yields to other fibers instead |
| `Clock.source` / `Clock.source=(source : Clock::Source)` | `Clock::Source` | The process-wide source |
| `Clock.use(source : Clock::Source, &)` | the block's value | Installs *source*, yields it, and restores the previous source afterwards, also when the block raises |

### Sources

| Class | Does |
| --- | --- |
| `Clock::Source` | The abstract source: `now` and `instant` are abstract; `coarse_nanoseconds` follows `instant` and `sleep` calls `::sleep` unless a subclass overrides them |
| `Clock::System` | The default: `Time.utc` and `Time.instant`. On Linux, `coarse_nanoseconds` reads `CLOCK_MONOTONIC_COARSE` |
| `Clock::Fake.new(start : Time = Time.utc)` | Moves only when told to. `now` starts at *start* |

`Clock::Fake` methods:

| Method | Moves |
| --- | --- |
| `advance(span : Time::Span)` | `now` and `instant` together |
| `step_wall_clock(span : Time::Span)` | `now` alone, like an NTP correction or a manual change; `instant` stays where it is. *span* may be negative |
| `sleep(span : Time::Span)` | `advance(span)`, then `Fiber.yield` |

```crystal
require "azu"

fake = Azu::Clock::Fake.new(Time.utc(2026, 1, 1))
Azu::Clock.use(fake) do
  started = Azu::Clock.instant
  fake.advance(10.minutes)
  Azu::Clock.now               # => 2026-01-01 00:10:00Z
  fake.step_wall_clock(-1.hour)
  Azu::Clock.now               # => 2025-12-31 23:10:00Z
  Azu::Clock.instant - started # => 00:10:00
end
```

## Behavior

These read `Azu::Clock`:

| Reader | Reads |
| --- | --- |
| `Cache::MemoryStore` entry TTLs | `instant` |
| `Handler::Throttle` request windows and blocks | `instant` |
| `Handler::CSRF` timestamps of `SignedDoubleSubmit` tokens, and their age check against `cookie_max_age` | `now` |
| Spark join tokens (`token_ttl`) and state snapshots (`snapshot_ttl`) | `now` |
| Spark's per-connection event rate limit (`events_per_second`, `event_burst`) | `instant` |
| `Presence::Store::Memory` leases, and `Store::Redis` with `server_time: false` | `now` |
| `Azu::Redis` pool: idle time before the `PING` health check, and the wait between retries | `instant`, `sleep` |
| `Handler::Static`: how often it looks at the public directory again | `coarse_nanoseconds`, `now` |
| `Azu::Testing::Client` and its cookie jar: cookie expiry | `now` |

`Azu::Testing::Client.new(app, clock: Azu::Clock::Fake.new)` installs its clock around each of its requests, and
`client.advance(span)` moves it (see [Testing](testing.md#time)).

## Limits

- The source is process-wide. Swapping it while other fibers read the clock is not supported: install a fake in
  specs, around code that runs in the spec's fiber or a client's requests.
- These do not read it: the date helpers of templates (`time_ago`, `relative_time`, `distance_of_time_between`,
  ...), which use `Time.utc`; Spark's heartbeat and `idle_timeout`; the Redis pool's checkout timeout; and expiry
  that Redis enforces itself (a `Cache::RedisStore` TTL, the Presence leases of `Store::Redis` with server time).
- Advancing a fake clock does not run timers, `sleep` calls on the system clock or `select` timeouts.

## See also

- [Testing](testing.md)
- [Cache](cache.md)
- [Redis](redis.md#retries)

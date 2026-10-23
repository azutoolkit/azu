# Presence

`Azu::Presence` answers "who is in this topic right now?" across processes. A *key* (a user id, a session) is
tracked in a topic with some metadata; `list` returns the keys that are present, and every change is published
as a join/leave diff through [`Azu::PubSub`](../../how-to/real-time/broadcast-messages.md) on `presence:<topic>`.

## Track, list, untrack

```crystal
require "azu"

meta = Azu::Presence.track("room:1", "alice", {name: "Alice", device: "phone"})
Azu::Presence.track("room:1", "alice", {name: "Alice", device: "laptop"})

Azu::Presence.list("room:1")                # => {"alice" => [two metas, oldest first]}
Azu::Presence.untrack("room:1", "alice", meta.ref) # removes the phone only; alice is still listed
Azu::Presence.untrack("room:1", "alice")           # removes what this node tracked for alice
```

- `track(topic, key, meta = nil) : Meta` adds one `Meta` to the key. Several calls for the same key (several
  sockets, tabs or nodes) make one user with several metas.
- `Meta` has `ref` (unique across the cluster, `<node>.<counter>`), `node`, `key`, `data` (a `JSON::Any`) and
  `joined_at` (unix milliseconds).
- `untrack(topic, key, ref = nil)` removes the metas this node tracked for *key*, or only *ref*, and returns them.
  A node can only remove its own metas.
- `list(topic)` returns the live metas of every node, by key.

Limits keep a topic bounded: a key is at most 256 bytes, a meta at most `max_meta_bytes` of JSON (1024) and a
node tracks at most `max_entries` (10 000) metas. `Azu::Presence::LimitExceeded` is raised beyond them.

## Diffs

```crystal
require "azu"

subscription = Azu::Presence.subscribe("room:1") do |diff|
  diff.joins.each { |key, metas| puts "#{key} +#{metas.size}" }
  diff.leaves.each { |key, metas| puts "#{key} -#{metas.size}" }
  puts "arrived: #{diff.arrived}, departed: #{diff.departed}"
end
subscription.cancel
```

`joins` and `leaves` carry every meta added or removed, by key. `arrived` names the keys that were absent
before, `departed` those that are absent now: a user with two devices *departs* only when the last meta goes.
The wire format is the JSON of `Azu::Presence::Diff`.

## Channels

Include `Azu::Presence::Tracked` in a channel to tie presence to its socket. `track_presence` remembers what it
tracked and `teardown` untracks it, however the socket ends (close frame, dropped peer, a handler that raised).
Existing channels are unaffected unless they include the module.

```crystal
require "azu"

class RoomChannel < Azu::Channel
  include Azu::Presence::Tracked

  def on_connect
    presence_updates("room:1") # diffs reach on_broadcast, which sends them to the socket
    track_presence("room:1", params["user"], {device: params["device"]?})
  end

  def on_message(message : String)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
  end
end
```

Subscribe before tracking if the socket should see its own join.

## Backends

`Azu::Presence.default` is a `Tracker` over `Store::Memory` (one process). For several processes give every
node the same `Store::Redis` and use the Redis PubSub backend, so diffs cross nodes as well:

```crystal
require "azu"

url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
Azu::PubSub.backend = Azu::PubSub::Redis.new(url)
Azu::Presence.default = Azu::Presence::Tracker.new(Azu::Presence::Store::Redis.new(url), ttl: 30.seconds)
```

`Tracker.new(store, node:, ttl:, heartbeat:, interval:, pub_sub:, max_meta_bytes:, max_entries:)`:

| Option | Default | Meaning |
| --- | --- | --- |
| `node` | random per boot | Node id; the prefix of every `ref`. Keep it unique per process. |
| `ttl` | 30 seconds | How long a lease lives without being renewed. |
| `heartbeat` / `interval` | on / `ttl / 3` | The fiber that renews the lease; `heartbeat: false` leaves `sweep` to you. |
| `pub_sub` | `Azu::PubSub.backend` | Where diffs are published. |

A store is a Strategy: implement `Azu::Presence::Store` (`put`, `delete`, `stored`, `renew`, `leases`, `forget`,
`evict`) and the shared expiry logic in `live` comes with it.

## Guarantees

- **Merging.** Each node owns the metas it tracked and is the only one to add or remove them, so a topic is the
  union of per-node sets that never overlap. Merging is commutative and idempotent and needs no coordination
  (a conflict-free replicated set per node, with a per-node monotonic counter in every `ref`).
- **Crashes.** Every node renews a lease every `ttl / 3` and re-asserts its metas then. When a lease is older
  than `ttl` (SIGKILL, power loss, partition), `list` stops returning the node's metas on every other node and
  the next sweep or `list` there publishes the `leaves`. A node that was only paused comes back by itself on
  its next beat.
- **Diffs are hints.** They are not queued: a subscriber that was disconnected misses them and the same leave
  can arrive from several nodes. Apply them by `ref` and call `list` after a reconnect. `arrived` and
  `departed` are decided by the node that made the change, so two nodes tracking the same new key at the same
  instant may both report `arrived`.
- **Clocks.** Leases are wall-clock times from `Azu::Clock.now` written by one node and read by another: keep
  node clocks within a fraction of the `ttl`. Specs install `Azu::Clock::Fake`, advance it and call `sweep`.
- **Cost.** `list` reads the whole topic; track users per room, not one global topic with millions of metas.

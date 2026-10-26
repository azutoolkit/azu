# Scale real-time features out

This guide shows how to run several Azu processes that share WebSocket broadcasts and
[presence](../../reference/api/presence.md). The rest of scaling is in [Scale Horizontally](scale-horizontally.md).

## Topology

```
 client A ── ws ──> node A ──┐                 ┌── node B <── ws ── client B
                  publish  ──> Redis (pub/sub + presence hashes) <── PSUBSCRIBE
```

Every node runs the same code and connects to one Redis. A load balancer may send a client to any node; there is
no sticky routing and no leader.

```crystal
require "azu"

url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
Azu::PubSub.backend = Azu::PubSub::Redis.new(url)
Azu::Presence.default = Azu::Presence::Tracker.new(
  Azu::Presence::Store::Redis.new(url),
  node: ENV.fetch("HOSTNAME") { Random::Secure.hex(6) },
  ttl: 30.seconds)
```

Set both before the first connection is served. Give every process its own `node` (a hostname or pod name is
fine, and a fresh random id after each restart is better: a restarted process must not reuse the counter of its
previous life while old entries may still be expiring).

## Connections

- **Subscriber.** `PubSub::Redis` keeps one dedicated connection in `PSUBSCRIBE` mode per process (not taken from
  the pool), opened when the first channel subscribes. It fans messages out to the local subscribers; handlers run
  on its fiber, so they must only enqueue.
- **Publisher and presence store.** Both use the [`Azu::Redis`](../../reference/api/redis.md) pool: one connection
  per concurrent command, opened on demand up to 2 (when built from a URL), with a 5 second timeout. Built from the same URL
  they share one pool, so a quiet node has one pooled connection plus the subscriber. A dead connection is replaced
  and the command retried once.
- **Presence data.** Presence data lives in the hashes
  `azu:presence:t:<topic>` and `azu:presence:nodes`; use a distinct prefix (second argument) per environment that
  shares a Redis.

## Reconnect behaviour

- When the subscriber connection drops, the listener retries with exponential backoff (0.5 s doubling to
  15 s). **Broadcasts published while it was down are lost**: Redis pub/sub does not queue. After a reconnect a
  client should fetch current state (the page, `Presence.list`) instead of assuming it saw everything.
- Presence heals itself: every beat re-asserts the node's metas, so a Redis restart or flush loses entries only
  until the next beat (`ttl / 3`). `list` is right again then; the diffs for it (joins and `arrived`) are
  published by the other nodes that watch the topic.
- A failed beat is logged and retried at the next interval; if Redis stays down for more than the `ttl`, other
  nodes consider this node gone and publish its users as departed, then publish them as arrived again after the
  first beat that succeeds.

## Presence guarantees

- A user with sockets on several nodes is one key with several metas; it `departed` only when the last one goes.
- A node killed without cleanup (SIGKILL, OOM, lost host) disappears from every other node's `list` once its lease
  is `ttl` old, and the surviving nodes publish the `leaves`.
- Leases follow the Redis clock, so the nodes' own clocks do not matter.
- Diffs can be missed or repeated (check the `seq` of each `node`); `list` is the truth. See [Guarantees](../../reference/api/presence.md#guarantees).

## Testing it

`spec/azu/scale_out_spec.cr` (opt-in with `AZU_TEST_SCALE=1`; CI sets it; the compiled fixture is cached) compiles `spec/fixtures/scale_node.cr` once and starts it twice as real OS
processes against one Redis (`AZU_TEST_REDIS_URL`, default `redis://localhost:6379/0`). It connects a WebSocket
client to each node, checks that a message from either reaches the other, that both users are listed by both
nodes, then sends SIGKILL to one node and waits for its user to leave the other node's list. Separate processes
were chosen over two `Azu::App` values in one process because the global PubSub backend and presence tracker are
per process, and because a killed process is the only honest way to test lease expiry.

---
description: "The topic bus channels, Spark components and Presence share: subscribe, broadcast, the in-memory and Redis backends, and writing a backend of your own."
---

# PubSub

`Azu::PubSub` delivers a message broadcast to a topic to every handler subscribed to that topic. Channels
(`Channel#subscribe`), Spark components and [Presence](presence.md) all go through it. It comes with `require "azu"`;
the default backend keeps subscriptions in the memory of one process, and `PubSub::Redis` carries broadcasts between
processes. It is not a queue: nothing is stored, and a message nobody is subscribed to is dropped.

```crystal
require "azu"

subscription = Azu::PubSub.subscribe("news") do |message|
  puts "#{message.topic}: #{message.payload}"
end

Azu::PubSub.broadcast("news", "plain text")      # news: plain text
Azu::PubSub.broadcast("news", {title: "Hello"}) # news: {"title":"Hello"}

subscription.cancel
```

## API

| Method | Returns | Notes |
| --- | --- | --- |
| `PubSub.subscribe(topic : String, &handler : Message ->)` | `Subscription` | The handler receives every message broadcast to *topic* until the subscription is cancelled |
| `PubSub.broadcast(topic : String, payload : String)` | `Nil` | Sends the string as it is |
| `PubSub.broadcast(topic : String, data)` | `Nil` | Sends `data.to_json` |
| `PubSub.backend` | `Backend` | The current backend; a `PubSub::Memory` is built on first use |
| `PubSub.backend=(backend : Backend)` | `Backend` | Replaces the backend and calls `shutdown` on the previous one. Set it once, at boot |
| `PubSub.shutdown` | `Nil` | Shuts the backend down and forgets it; the next use starts a fresh `Memory`. `Azu.shutdown` calls it |
| `PubSub.reserved?(topic : String)` | `Bool` | True for topics that start with `RESERVED_PREFIX` (`"presence:"`) |

`Subscription` has `topic`, `cancelled?` and `cancel`. `cancel` can be called more than once, and no message is
delivered once it returns.

`PubSub::Message` is a record of `topic` and `payload` (both `String`). `json(Type)` decodes the payload with
`Type.from_json`:

```crystal
require "azu"

struct Headline
  include JSON::Serializable

  getter title : String
end

subscription = Azu::PubSub.subscribe("news") do |message|
  puts message.json(Headline).title # => Hello
end
Azu::PubSub.broadcast("news", {title: "Hello"})
subscription.cancel
```

### Backends

| Backend | Reach | Notes |
| --- | --- | --- |
| `PubSub::Memory.new` | one process | The default. No fibers and no connections; `subscriber_count` returns the number of live subscriptions |
| `PubSub::Redis.new(url = PubSub::Redis.default_url, prefix = "azu:pubsub:", listen_timeout = 2.seconds)` | every process on the same Redis and prefix | Acquires the shared [`Azu::Redis`](redis.md) client for *url* (a pool of 2, 5 second timeouts) and closes it on `shutdown` |
| `PubSub::Redis.new(client : Azu::Redis::Client, prefix = "azu:pubsub:", owned = false, listen_timeout = 2.seconds)` | the same | Uses a client you built; it stays yours to close |

`PubSub::Redis.default_url` reads `PUBSUB_REDIS_URL`, then `REDIS_URL`, then `redis://localhost:6379/0`:

```crystal
require "azu"

Azu::PubSub.backend = Azu::PubSub::Redis.new(Azu::PubSub::Redis.default_url)
```

### Writing a backend

A backend is a subclass of `Azu::PubSub::Backend` with three abstract methods, plus `shutdown` when it owns fibers or
connections (the default does nothing):

| Method | Does |
| --- | --- |
| `subscribe(topic : String, &handler : Message ->) : Subscription` | Records a `Subscription.new(topic, self, &handler)` and returns it |
| `unsubscribe(subscription : Subscription) : Nil` | Forgets it; `Subscription#cancel` calls this |
| `broadcast(topic : String, payload : String) : Nil` | Delivers the message, here or through a transport |
| `shutdown : Nil` | Releases what the backend holds |

`PubSub::Subscribers` is the thread-safe table of subscriptions the built-in backends use: `add`, `remove`,
`dispatch(message)` (delivers to a copy of the topic's list, outside its lock), `size` and `clear`. This backend
delivers in process, like `Memory`, and hands every broadcast to a sink as well:

```crystal
require "azu"

class ForwardingBackend < Azu::PubSub::Backend
  def initialize(@sink : Proc(String, String, Nil))
    @subscribers = Azu::PubSub::Subscribers.new
  end

  def subscribe(topic : String, &handler : Azu::PubSub::Message ->) : Azu::PubSub::Subscription
    subscription = Azu::PubSub::Subscription.new(topic, self, &handler)
    @subscribers.add(subscription)
    subscription
  end

  def unsubscribe(subscription : Azu::PubSub::Subscription) : Nil
    @subscribers.remove(subscription)
  end

  def broadcast(topic : String, payload : String) : Nil
    @sink.call(topic, payload)
    @subscribers.dispatch(Azu::PubSub::Message.new(topic, payload))
  end

  def shutdown : Nil
    @subscribers.clear
  end
end

Azu::PubSub.backend = ForwardingBackend.new(->(topic : String, payload : String) { puts "#{topic} #{payload}"; nil })
```

A backend that spans processes publishes in `broadcast` and calls `dispatch` from the fiber that receives messages
from its transport, as `PubSub::Redis` does.

## Behavior

- **Handlers run on the broadcaster's fiber.** With `Memory`, `broadcast` calls every handler of the topic before it
  returns; with `Redis`, the listener fiber calls them. A slow handler holds up the broadcaster (or every other
  topic of the process), so a handler enqueues the work and returns.
- A handler that raises is logged (`Azu::PubSub`, at error) and the other handlers of the message still run.
- A handler may subscribe and cancel subscriptions: delivery works on a copy of the topic's subscriptions.
- **Reserved topics.** Presence publishes its diffs on `presence:<topic>`. `Channel#subscribe` and
  `Channel#broadcast` raise `ArgumentError` for those topics, because a channel's topic often comes from the
  client; code that calls `Azu::PubSub` directly is trusted.
- Subscriptions made with `Channel#subscribe` end with the connection.

### The Redis backend

- Nothing connects until the first `subscribe` or `broadcast`.
- One dedicated connection, outside the pool, listens on `PSUBSCRIBE <prefix>*` and dispatches to the local
  subscribers. When it drops, the listener reconnects with jittered exponential backoff (0.5 seconds, doubling up to
  15) until `shutdown`. Messages published while it is away are lost.
- `broadcast` publishes `<prefix><topic>` through the shared pool; a dead connection is replaced and the publish
  retried as the client's `retry` setting allows, and a failure beyond that is raised to the broadcaster.
- `subscribe` returns once Redis has confirmed the pattern subscription, so a broadcast made right after it is
  delivered. When no confirmation comes within `listen_timeout`, one warning is logged, `subscribe` returns, and later
  subscribers stop waiting until the confirmation arrives.
- Processes that should exchange messages use the same Redis and the same prefix; environments that share a Redis
  use distinct prefixes.

## Limits

- Delivery is at most once. There is no history, acknowledgement or replay: a process that is not subscribed, or is
  reconnecting, misses the message.
- There is one backend per process, shared by every `Azu::App` in it.
- Topics have no authorization: check that a user may join a topic before subscribing to a name the client chose.

## See also

- [Channel](channel.md)
- [Presence](presence.md)
- [Broadcast messages](../../how-to/real-time/broadcast-messages.md)
- [Real-time across processes](../../how-to/deployment/scale-horizontally.md#real-time-across-processes)

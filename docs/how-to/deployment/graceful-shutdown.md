---
description: See what happens to requests, streams and WebSockets when an Azu app is told to stop, and make a long-lived response cooperate.
---

# Shut down gracefully

## What a stop does

`SIGTERM` and `SIGINT` (and `Azu::App#stop` from code) run these steps, all bounded by one
`config.shutdown_timeout` (`SHUTDOWN_TIMEOUT` seconds, 30 by default):

1. The app begins shutting down. From now on requests that arrive on connections that are still open get `503` with
   `Connection: close` and `Retry-After: 1`.
2. Every open WebSocket is sent a close frame with code **1001** (going away) immediately, not after the requests
   finish. Browsers and Spark clients reconnect, and a load balancer sends them to another instance. A socket that
   registers after this point is closed with 1001 without `on_connect` running; one that registered a moment before still runs `on_connect` and is then closed.
3. The shutdown signal is raised for streaming responses (see below).
4. The listener is closed, and the app waits for what is still in flight: normal requests, streams that have not
   finished and WebSockets whose peer has not answered the close frame yet.
5. If anything is left when the timeout passes, `start` logs a warning and goes on to `Azu.shutdown`, which closes
   Spark connections and the PubSub backend.

Closing the sockets at the start, rather than after the requests, means a quiet WebSocket never holds up the drain,
and clients start reconnecting while the slow requests are still finishing.

## Server-sent events and other streams

A streamed response is a request in flight until its handler returns. Without help it would hold the drain until the
timeout, so a long-lived handler asks whether the app is shutting down:

```crystal
require "azu"

struct EventsEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/event-stream"
    until Azu.shutting_down?
      context.response << "data: tick\n\n"
      context.response.flush
      sleep 1.second
    end
    context
  end
end
```

`Azu.shutting_down?` polls. To wake up at once instead of at the next poll, wait on `Azu.shutdown_signal`, a channel
that is closed when shutdown begins:

```crystal
require "azu"

struct LiveEvents
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/event-stream"
    loop do
      select
      when Azu.shutdown_signal.receive?
        break
      when timeout(15.seconds)
        context.response << ": keep-alive\n\n"
        context.response.flush
      end
    end
    context
  end
end
```

Both read the app that is serving the request, also in a channel's callbacks (`on_connect`, `on_message`) and in a fiber started with `Azu.spawn_scoped`. Outside a request
`Azu.shutting_down?` is false and the signal never closes. A handler that ignores them still works: it is waited for
until `shutdown_timeout`, then dropped with the process.

## WebSockets

Nothing to write: `Azu::Channel` sockets are registered with the app that accepted them. The app sends the 1001 close
frame, `on_close` runs with the code the peer answers with (normally 1001 too), and subscriptions are released. A peer that never
answers is waited for until `shutdown_timeout`.

## Several apps

Each `Azu::App` tracks its own sockets and requests. `Azu.start` drains `Azu::App.default`; for another app call
`app.stop` (or `begin_shutdown` then `drain`) yourself. A mounted app belongs to the app that owns the server.

## Testing it

`app.stop(timeout)` returns true when nothing was left. Bind the server on `bind_unused_port`, open an
`HTTP::WebSocket` and an `HTTP::Client` request against it, call `stop`, and assert the close code is
`HTTP::WebSocket::CloseCode::GoingAway`.

## See also

- [Scale Horizontally](scale-horizontally.md)
- [Deploying to production](../../tutorials/deploying-to-production.md)
- [Configuration options](../../reference/configuration/options.md)

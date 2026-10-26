---
description: "Serve two Azu::App values on two ports from one program, stop one of them, and combine them with the include Azu facade."
---

# Run several apps in one process

Each `Azu::App` has its own configuration, router, handler chain and server, so one program can serve a public site
on one port and an internal app on another. The example serves a site on port 8080 and an operations app on the
loopback interface, port 9090.

## Build the apps

<!-- prelude -->
```crystal
require "azu"

struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

struct HomeEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("home")
  end
end

struct StatsEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("requests: 0")
  end
end
```

<!-- prelude -->
```crystal
site = Azu::App.new
site.config.port = 8080
site.routes { get "/", HomeEndpoint }

ops = Azu::App.new
ops.config.host = "127.0.0.1"
ops.config.port = 9090
ops.routes { get "/stats", StatsEndpoint }
```

Set every app's port. A new app reads the same environment variables as the global configuration (`PORT`, `HOST`,
`CRYSTAL_ENV`, ...), so two apps left alone share a port.

{% hint style="warning" %}
`port_reuse` is on by default, so a second app on a port that another app already listens on binds without an
error, and the kernel then spreads the connections over the two: one request reaches the site, the next the
operations app.
{% endhint %}

## Start both

`start` blocks until the app stops, so start one in a fiber and wait for it before the program ends:

```crystal
ops_done = Channel(Nil).new(1)
spawn(name: "ops") do
  ops.start
ensure
  ops_done.send(nil)
end

site.start
ops_done.receive
```

- **Signals.** `SIGINT` and `SIGTERM` stop every app started with `start`: there is one trap for the process.
  Both apps refuse new requests, close their servers and drain within their own `shutdown_timeout`.
- **Teardown.** `Azu.shutdown` (Spark, presence, PubSub, the `Azu.on_shutdown` hooks, the Redis pools) runs once,
  after the last app has stopped. Without `ops_done.receive` the program could end while the operations app is
  still draining, before the teardown runs.
- **Bind errors.** A port held by another program raises in the `start` that binds it; in the fiber above that ends
  the operations app only. Rescue it and call `site.stop` if one app must not run without the other.

A program that handles signals itself passes `signals: false` and calls `stop`; one that keeps using PubSub, the
database pools or Redis after the apps stop passes `teardown: false`:

```crystal
spawn { ops.start(signals: false, teardown: false) }
```

## Stop one app

```crystal
ops.stop # => true when no request was dropped
```

`stop` refuses new requests with `503`, closes the server and waits up to `ops.config.shutdown_timeout` for the
requests in flight; then `ops.start` returns. The site keeps serving, and the framework parts stay up until the last
app has stopped. A stopped app does not start again (`Azu::App::AlreadyStopped`): build a new `Azu::App` to serve
the routes again.

## Give each app its own handlers

`start` without an argument uses `default_handlers`, which builds new instances on every call. A list you pass is
used as given, and a handler instance can be in one chain only: a second app started with the same instances raises
`ArgumentError` ("Azu::Handler::RequestId is already part of a chain; use one handler instance per server").
Build the list in a method:

```crystal
def handlers : Array(HTTP::Handler)
  [
    Azu::Handler::RequestId.new,
    Azu::Handler::Logger.new,
    Azu::Handler::Rescuer.new,
  ] of HTTP::Handler
end

site.start(handlers) # and ops.start(handlers) in the fiber
```

`Handler::Logger` without a `log:` writes to the log of the app serving the request, so each app's lines go to its
own `config.log`.

## With the include Azu facade

The facade's app is `Azu::App.default`, built around the global `Azu::CONFIG`: `MyApp.start` is
`Azu::App.default.start`, and the endpoints that declare their routes with a verb macro (`get "/"` in the endpoint
body) belong to it. Run the second app next to it:

```crystal
module MyApp
  include Azu

  configure do |config|
    config.port = 8080
  end
end

ops = Azu::App.new
ops.config.host = "127.0.0.1"
ops.config.port = 9090
ops.routes { get "/stats", StatsEndpoint }

ops_done = Channel(Nil).new(1)
spawn(name: "ops") do
  ops.start
ensure
  ops_done.send(nil)
end

MyApp.start
ops_done.receive
```

To serve an endpoint that declares its routes with verb macros from the second app too, register the type there
with `endpoint` (see [Router](../../reference/api/router.md#registering-an-endpoint-type-on-an-app)).

## See also

- [App](../../reference/api/app.md#start): what `start` does, step by step
- [Apps, configuration and scope](../../explanation/architecture/apps-and-scope.md)
- [Shut down gracefully](../deployment/graceful-shutdown.md)
- [Mount an app under a prefix](mount-an-app.md)

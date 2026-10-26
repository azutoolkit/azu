---
description: "Compose a chain of HTTP handlers with `Azu::HandlerPipeline`, and how it differs from the handler array an app starts with."
---

# Handler pipeline

`Azu::HandlerPipeline` links handlers into one chain, in the order they are added, and returns the first: an
`HTTP::Handler` you can hand to an `HTTP::Server` or call yourself. It comes with `require "azu"`. It is not how an
app's middleware is configured: `App#start` and the `include Azu` facade's `start` take an array of handlers and
chain it themselves (see [App](app.md)), and they refuse a handler that is already part of a chain, which every
handler of a built pipeline but the last one is.

```crystal
require "azu"

struct HelloEndpoint
  include Azu::Routable

  def call(context : HTTP::Server::Context)
    context.response << "hello"
  end
end

app = Azu::App.new
app.routes { get "/hello", HelloEndpoint }

pipeline = Azu::HandlerPipeline.new
  .use(Azu::Handler::RequestId.new)
  .use_if(ENV["ENABLE_CORS"]? == "true", Azu::Handler::CORS.new(origins: ["https://app.example.com"] of String | Regex))
  .use { |context| context.response.headers["X-Served-By"] = "pipeline" }
  .use(app.dispatcher([Azu::Handler::Rescuer.new] of HTTP::Handler))

server = HTTP::Server.new(pipeline.build)
server.bind_tcp("127.0.0.1", 8080)
# server.listen
```

`app.dispatcher(handlers)` is the app's own chain (its scope, *handlers*, then the router) as one handler, so it
goes last.

## API

| Method | Returns | Notes |
| --- | --- | --- |
| `HandlerPipeline.new` | `HandlerPipeline` | An empty pipeline |
| `use(handler : HTTP::Handler)` | `self` | Appends *handler* |
| `use(&block : HTTP::Server::Context -> Nil)` | `self` | Appends a handler that runs the block, then calls the next handler |
| `use_if(condition : Bool, handler : HTTP::Handler)` | `self` | Appends *handler* only when *condition* is true |
| `build` | `HTTP::Handler` | Sets each handler's `next` to the one after it and returns the first; raises `HandlerPipeline::EmptyPipelineError` (`Cannot build an empty handler pipeline`) when empty |
| `build?` | `HTTP::Handler?` | `nil` when empty, else `build` |
| `size` | `Int32` | Handlers added |
| `empty?` | `Bool` | |
| `clear` | `self` | Removes every handler |

## Behavior

- Handlers run in the order they were added. Each one decides whether to call `call_next(context)`.
- `build` does not set the last handler's `next`. When the last handler calls `call_next`, Crystal's
  `HTTP::Handler` answers `404 Not Found`, so end the pipeline with the handler that answers the request, such as
  `app.dispatcher`.
- `build` changes the handlers it links: a handler instance belongs to one chain, so build a pipeline once and use
  new handler instances for a second one.

### Pipelines and `App#start`

`App#start(handlers)` builds the chain from an array: the app's scope first, then the handlers in order, then the
router. It raises `ArgumentError` for a handler whose `next` is already set, so a built pipeline of two or more
handlers cannot be passed to it:

```crystal
require "azu"

pipeline = Azu::HandlerPipeline.new
  .use(Azu::Handler::RequestId.new)
  .use(Azu::Handler::Rescuer.new)

app = Azu::App.new
app.server([pipeline.build] of HTTP::Handler)
# ArgumentError: Azu::Handler::RequestId is already part of a chain; use one handler instance per server
```

To serve an app with `start`, pass the array itself (`MyApp.start [RequestId.new, Logger.new, Rescuer.new] of HTTP::Handler`).
A pipeline ending in `app.dispatcher` and served by an `HTTP::Server` of your own runs its handlers before the
app's scope: they see the global configuration (`Azu::CONFIG`) instead of the app's, and nothing of `App#start`
happens (no `prepare`, signal handling, draining or `Azu.shutdown`).

## Limits

- There is no way to read the handlers back, insert one at a position or remove one: rebuild the pipeline.
- `use_if` decides when the pipeline is built, not per request.

## See also

- [App](app.md)
- [Built-in handlers](../handlers/built-in.md)
- [Create custom middleware](../../how-to/middleware/create-custom-middleware.md)

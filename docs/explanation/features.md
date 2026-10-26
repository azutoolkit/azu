---
description: What Azu ships today, grouped by what you are trying to do, with a link to the guide or reference for each.
---

# Everything in the box

A feature marked **opt-in** needs its own `require`; `require "azu"` alone does not load it. Azu is 0.x software: [breaking changes](../reference/breaking-changes.md) are listed per release.

## Routing and endpoints

- **Typed endpoints.** `Endpoint(Request, Response)` declares what a route accepts and returns, and the compiler holds you to it. [Endpoint](../reference/api/endpoint.md), [Create an endpoint](../how-to/endpoints/create-endpoint.md).
- **Radix router.** Static, `:param` and `*wildcard` segments, `scope` for prefixes, `HEAD` and `OPTIONS` registered with every `GET`, and `_method` overrides for HTML forms. [Router](../reference/api/router.md).
- **Mounting.** `mount` serves another app below a prefix, and `Endpoint.path` builds links that include it. [Mount an app under a prefix](../how-to/apps/mount-an-app.md), [Router](../reference/api/router.md#mounting-another-app).
- **Apps as values.** `Azu::App.new` gives you an app with its own configuration, router and handlers, so several can live in one process. `include Azu` is the one-app shortcut over the same class. [App](../reference/api/app.md).
- **Generated link and form helpers.** Each endpoint gets `link_to_*`, `form_for_*` and `button_to_delete_*` template helpers that use its real path. [Template helpers](../reference/templates/helpers.md#type-safe-endpoint-helpers).

## Request contracts and validation

- **Request contracts.** A struct that includes `Azu::Request` is built from the path, query string, form or JSON body, and validated before your endpoint runs. [Request](../reference/api/request.md).
- **Validation rules.** `presence`, `required`, `size`, `match`, `in`, `exclude`, `eq`, `gt`, `gte`, `lt` and `lte`, with custom messages. [Validate requests](../how-to/validation/validate-requests.md).
- **Problem documents.** The endpoint answers a failed contract with `422` and the failing fields, as RFC 7807 JSON when the request accepts JSON. [Handle validation errors](../how-to/validation/handle-validation-errors.md).
- **Parameters and uploads.** Typed access to route, query and body parameters, and multipart uploads with size limits. [Handle parameters](../how-to/endpoints/handle-parameters.md), [Handle file uploads](../how-to/file-handling/handle-file-uploads.md).

## Responses and errors

- **Response objects.** A response type turns your data into the body, and `Response::Empty` covers redirects and no-content answers. [Response](../reference/api/response.md).
- **Content negotiation.** One endpoint can answer JSON, HTML, XML or text, chosen from the `Accept` header, with `406` when nothing fits. Negotiated responses carry `Vary: Accept` so shared caches stay correct. [Content negotiation](../reference/api/content-negotiation.md).
- **Streaming and server-sent events.** Stream a body or push events to a browser. [Streaming and SSE](../reference/api/streaming.md).
- **Error classes and error pages.** `Response::Error` subclasses map to status codes, `Handler::Rescuer` turns exceptions into JSON, text or HTML answers, and internal details stay out of production responses. [Error types](../reference/errors/error-types.md), [Handle errors gracefully](../how-to/errors/handle-errors-gracefully.md).

## Real-time

- **WebSocket channels.** `Azu::Channel` classes with connect, message and close callbacks, limits on message size and origin. [Channel](../reference/api/channel.md), [Create a WebSocket channel](../how-to/real-time/create-websocket-channel.md).
- **Pub/sub.** `Azu::PubSub` broadcasts to topics in memory, or through Redis across processes. [Broadcast messages](../how-to/real-time/broadcast-messages.md), [Real-time across processes](../how-to/deployment/scale-horizontally.md#real-time-across-processes).
- **Presence.** Track who is in a topic across nodes and subscribe to joins and leaves. [Presence](../reference/api/presence.md).
- **Spark live views.** Server-rendered Spark components (`Azu::Spark::Component`) with `prop`, `state` and `event def`; the browser sends events over a WebSocket and gets back only the HTML that changed, with reconnect and rehydration. [Build a live component](../how-to/real-time/build-live-component.md), [Spark live views](spark-live-views.md), [Spark client](../reference/spark-client.md).
- **Spark security and limits.** A component can only be joined with a signed, expiring token (`SPARK_SECRET` is required in production and staging), reconnect snapshots are signed and size limited, and each connection has an event rate limiter and a frame size limit. [Spark live views](spark-live-views.md#security-model).
- **TCP_NODELAY on WebSockets.** Upgraded sockets send small frames at once instead of waiting for a delayed ACK; switch it off with `WEBSOCKET_TCP_NODELAY=false`. [Options](../reference/configuration/options.md), [Understanding real-time](concepts/real-time.md).

## Templates and helpers

- **Jinja templates.** Crinja renders `.jinja` templates; outside development they are compiled once at boot, so a syntax error stops startup, and in development they reload on change. [Render HTML templates](../how-to/templates/render-html-templates.md), [Enable hot reload](../how-to/templates/enable-hot-reload.md), [Template engine](../reference/templates/engine.md).
- **Built-in helpers.** Forms with CSRF fields, links, assets, dates, numbers and HTML filters; register your own with `Azu::Helpers.filter` and `.function`. [Template helpers](../reference/templates/helpers.md).
- **Internationalization.** `t` and `l` helpers over YAML locale files, and `Handler::Locale` to pick the locale from `Accept-Language`. [i18n helpers](../reference/templates/helpers.md#i18n-helpers).
- **Markup components.** `Azu::Component` and the `Azu::Markup` DSL write static HTML in plain Crystal (live, stateful ones are Spark components). [Component](../reference/api/component.md).

## Security

- **CSRF protection.** Signed double-submit (the default), synchronizer-token and plain double-submit strategies; `CSRF_SECRET` is required in production. [Handler::CSRF](../reference/handlers/built-in.md#handlercsrf).
- **Security headers.** `Handler::SecurityHeaders` sets the common browser-side protections. [Handler::SecurityHeaders](../reference/handlers/built-in.md#handlersecurityheaders).
- **CORS.** No origin is allowed until you list it. [Handler::CORS](../reference/handlers/built-in.md#handlercors).
- **Throttling.** `Handler::Throttle` limits requests per address; `Handler::IpSpoofing` answers `403` when `X-Client-IP` or `X-Real-IP` disagree with `X-Forwarded-For`. [Handler::Throttle](../reference/handlers/built-in.md#handlerthrottle), [Handler::IpSpoofing](../reference/handlers/built-in.md#handleripspoofing).
- **Sessions.** Azu reads sessions through `Azu::SessionAdapter`; the [session shard](https://github.com/azutoolkit/session) fills it. [Use sessions](../how-to/middleware/use-sessions.md).
- **Secrets.** `Azu::Env.secret` reads a secret from the environment, makes up a random one outside the strict environments (`production` by default, widened with `AZU_STRICT_ENVS`) and refuses to boot without it inside them. [Azu::Env](../reference/configuration/env.md).

## Performance and operations

- **Caching.** `Azu.cache` with memory, Redis and null stores, TTLs and hit metrics. [Cache](../reference/api/cache.md), [Set up a memory cache](../how-to/caching/setup-memory-cache.md), [Set up a Redis cache](../how-to/caching/setup-redis-cache.md).
- **Shared Redis.** One pool, configuration and retry policy serve the cache, pub/sub and presence. [Redis](../reference/api/redis.md).
- **Static files.** `Handler::Static` with `except:` and `mime_types:`, byte ranges, weak `ETag`s with `304` answers, and long cache lifetimes for fingerprinted names. [Handler::Static](../reference/handlers/built-in.md#handlerstatic).
- **Compression and health checks.** `Handler::Compression` for gzip and deflate; `Handler::HealthCheck` answers `/health` for load balancers. [Handler::Compression](../reference/handlers/built-in.md#handlercompression), [Handler::HealthCheck](../reference/handlers/built-in.md#handlerhealthcheck).
- **Request ids and logging.** Every request gets an id that follows it into logs and error bodies; logging is structured and asynchronous, with `Handler::Logger` or the smaller `Handler::SimpleLogger`. [Add logging](../how-to/middleware/add-logging.md), [Handler::RequestId](../reference/handlers/built-in.md#handlerrequestid), [Handler::SimpleLogger](../reference/handlers/built-in.md#handlersimplelogger).
- **Graceful shutdown.** On SIGINT or SIGTERM Azu refuses new requests, closes WebSockets with a close frame and waits for requests in flight. [Shut down gracefully](../how-to/deployment/graceful-shutdown.md).
- **Instrumentation.** `Azu::Instrumentation` is the hook that metrics and APM code plug into; without a subscriber it costs a nil check. [Performance design](architecture/performance-design.md).
- **Injectable clock.** `Azu::Clock` drives every TTL and window, so specs advance time instead of sleeping. [Testing reference](../reference/api/testing.md).
- **Benchmark suite.** A reproducible comparison with other Crystal frameworks. [benchmark/README.md](https://github.com/azutoolkit/azu/blob/master/benchmark/README.md).

## Developer experience

- **Project generator.** The [Azu CLI](https://github.com/azutoolkit/azu_cli) creates projects and generates models, scaffolds, endpoints, channels and authentication, and has `azu dev`, `azu routes` and `azu doctor`. It is a separate tool. [Get started in 5 minutes](https://github.com/azutoolkit/azu#get-started-in-5-minutes).
- **Dev dashboard (opt-in: `azu/dev`).** Routes, configuration, logs, request timings, cache and component metrics in the browser, in development only. [Getting started](../tutorials/getting-started.md#5-the-development-dashboard), [Performance design](architecture/performance-design.md).
- **SQL and N+1 insight (opt-in: `azu/cql`).** Every CQL query is tied to the request that ran it, with slow-query and N+1 detection and a SQL playground in the dashboard. [CQL bridge](../reference/api/cql-bridge.md), [Database dashboard](../reference/database-dashboard.md).
- **Test client (opt-in: `azu/testing`).** Sends requests through the real handler chain and router, without a socket, and drives WebSockets and Spark components. [Testing](../reference/api/testing.md), [Test endpoints](../how-to/testing/test-endpoints.md), [Test WebSockets](../how-to/testing/test-websockets.md).
- **OpenAPI.** An OpenAPI 3.1 document generated from your contracts, served by `Azu::OpenAPI::Handler`. [OpenAPI](../reference/api/openapi.md).
- **`.env` files.** `Azu::Env.load_all` loads `.env`, `.env.<environment>` and `.env.local`, and `Azu::Env` has typed accessors. `require "azu"` already loads `azu/env`, but configuration reads `PORT`, `HOST` and `CRYSTAL_ENV` when `azu` is required, so call it first, as generated apps do: `require "azu/env"`, `Azu::Env.load_all`, then `require "azu"`. [Azu::Env](../reference/configuration/env.md).

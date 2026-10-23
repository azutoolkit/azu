# Built-in Handlers Reference

Azu ships handlers for the common middleware needs. They are all `HTTP::Handler`s in the `Azu::Handler`
namespace and are used the same way: build them, put them in the array given to `start`.

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

`MyApp.start` without an array serves `Azu::App#default_handlers`: `RequestId`, `Logger`, `Rescuer`,
`SecurityHeaders` and `Static` (see [Default stack](#default-stack)). An array you pass is used as given.

## Writing a handler

There is no `Azu::Handler::Base`. A handler includes `HTTP::Handler` and implements `call`:

```crystal
class MyHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    # before the rest of the chain
    call_next(context)
    # after it
  end
end
```

`call_next(context)` runs the next handler, or the router after the last one. Not calling it ends the request
there. A handler instance can be part of one chain only.

## Default stack

`Azu::App#default_handlers` builds fresh instances of:

| Handler | As configured by default |
|---|---|
| `RequestId` | header `X-Request-ID` |
| `Logger` | `config.log` |
| `Rescuer` | |
| `SecurityHeaders` | `hsts: config.tls?` |
| `Static` | `./public`, `fallthrough: true` |

## Handler::RequestId

```crystal
Azu::Handler::RequestId.new(header_name: "X-Request-ID")
```

Keeps the request id the client sent, or generates `req_<unix ms>_<hex>`. The id is written to the request and
response headers, and `Azu::RequestContext.current?.try(&.request_id)` returns it anywhere in the request's fiber
(logs, database instrumentation). Put it first.

## Handler::Logger

```crystal
Azu::Handler::Logger.new(log: Log.for("http"))
```

- `log : ::Log` - where lines go (default `Azu::CONFIG.log`, the `Azu` source).

Logs one `Info` line per request after the rest of the chain has run:

```text
127.0.0.1 ⤑ GET Path: /ok Endpoint: OkEndpoint Status: 200 Latency: 90.49µs
```

The endpoint is `unknown` when no route matched. Because it logs after `call_next`, a `Logger` placed outside
`Rescuer` reports the status the client got (a request that raised is logged with `Status: 500`). There are no
options to skip paths. See [How to Add Logging](../../how-to/middleware/add-logging.md).

## Handler::SimpleLogger

```crystal
Azu::Handler::SimpleLogger.new(log: Log.for("http"))
```

An alternative to `Logger` that reports through Azu's asynchronous logging pipeline: the line is written from a
spawned fiber after the request, at info for 2xx/3xx, warn for 4xx and error for 5xx, with method, path, endpoint,
status, latency, remote address, user agent and content length as fields. It also copies the request id into
`X-Request-ID`. Use one of `Logger` and `SimpleLogger`, not both.

## Handler::Rescuer

```crystal
Azu::Handler::Rescuer.new(log: Log.for("http.server"))
```

Catches what the handlers after it, the router and the endpoint raise and answers with an error response.

| Raised | Status |
|---|---|
| `Response::NotFound` (also an unrouted path) | 404 |
| `Response::BadRequest` | 400 |
| `Response::AuthenticationError` | 401 |
| `Response::AuthorizationError`, `Response::Forbidden` | 403 |
| `Response::TimeoutError` | 408 |
| `Response::PayloadTooLarge` | 413 |
| `Response::ValidationError` | 422 |
| `Response::RateLimitError` | 429 |
| `Response::DatabaseError` | 500 |
| `Response::ExternalServiceError` | 502 |
| any other `Response::Error` | its `status` |
| any other exception | 500 |

`HTTP::Server::ClientError` (the peer went away) is logged at debug level and not answered. A request that
breaks its contract raises `Response::ValidationError` before the endpoint's `call` runs; `Rescuer` is what turns
it into the `422` (without it the client gets Crystal's bare `500`, which was seen by running it).

The body is chosen by the first media type of the `Accept` header: JSON, HTML, XML or plain text, and plain text
without a header. In development the error includes the request context and HTML clients receive Azu's exception
page. In any other environment the context is `null` and HTML clients get the `error.html` template, except for an
unexpected exception, where the client gets a bare `500 Internal Server Error`.
Without `Rescuer`, an exception reaching Crystal's server becomes that same bare `500` and a stack trace in the log.

## Handler::SecurityHeaders

```crystal
Azu::Handler::SecurityHeaders.new(
  frame_options: "SAMEORIGIN",
  referrer_policy: "strict-origin-when-cross-origin",
  content_security_policy: nil,
  hsts: false,
)
```

Sets `X-Content-Type-Options: nosniff`, `X-Frame-Options`, `Referrer-Policy`, and, only when asked,
`Content-Security-Policy` (the string you pass) and `Strict-Transport-Security: max-age=31536000; includeSubDomains`
(`hsts: true`). A header the application already set is left alone, so one endpoint can loosen a policy. Enable
HSTS only for sites served over HTTPS; browsers remember it.

## Handler::Static

```crystal
Azu::Handler::Static.new(
  public_dir: "public",
  fallthrough: false,
  directory_listing: false,
  cache_control: "public, no-cache",
  cache_max_age: 31_536_000,
)
```

- `public_dir : String` - directory to serve (default `"public"`, relative to the working directory).
- `fallthrough : Bool` - pass requests that match no file to the next handler. Without it a missing file answers
  `404` itself and **no route behind `Static` is ever reached**; the default stack sets `fallthrough: true`.
- `directory_listing : Bool` - list directories without an `index.html`.
- `cache_control : String` - `Cache-Control` of files without a fingerprint.
- `cache_max_age : Int32` - seconds for fingerprinted files (default `config.assets.cache_max_age`, one year).

Behaviour seen by running it:

- A file whose name carries a content hash (`app-3f2a9c1b.css`) is sent with
  `public, max-age=31536000, immutable`; every other file with `cache_control` (`public, no-cache` by default).
- Responses carry a weak `ETag` and `Vary: Accept-Encoding`; a matching `If-None-Match` answers `304`.
- `Range: bytes=0-4` answers `206` with `Content-Range`; a range past the end answers `416`.
- `GET /` serves `index.html` of the directory.
- `.html .css .js .json .txt .svg .xml` and font files larger than 860 bytes are gzip or deflate compressed when the
  client accepts it.
- Methods other than `GET` and `HEAD` answer `405` with `Allow` (or fall through).
- A file in `public/` shadows a route with the same path, so keep only public files there.

## Handler::Compression

```crystal
Azu::Handler::Compression.new
```

The standard library's `HTTP::CompressHandler`: gzip or deflate for clients that send `Accept-Encoding`. It is not
in the default stack. `Static` already compresses and sets its own length, so place `Compression` after `Static`.

## Handler::CORS

```crystal
Azu::Handler::CORS.new(
  origins: ["https://app.example.com"] of (String | Regex),
  methods: %w(GET POST PUT DELETE),
  headers: %w(Content-Type Authorization),
  credentials: true,
  max_age: 600,
  expose_headers: ["X-Request-ID"],
)
```

- `origins` - allowed origins: exact strings, regexes, or `"*"`. **Empty by default**, which refuses every
  cross-origin request.
- `methods` - methods a preflight may ask for (default `POST PUT PATCH DELETE`).
- `headers` - request headers a preflight may ask for (default `Accept Content-Type`).
- `credentials : Bool` - send `Access-Control-Allow-Credentials: true`.
- `max_age : Int32?` - `Access-Control-Max-Age` of preflights.
- `expose_headers`, `vary` - extra `Access-Control-Expose-Headers` / `Vary` content.

Observed with an allowed origin `https://app.example.com`:

| Request | Result |
|---|---|
| `GET` without `Origin` | passes through, no CORS headers |
| `GET` from the allowed origin | `200` with `Access-Control-Allow-Origin` set to that origin and `Vary: Origin` |
| `GET` from another origin | `403 Forbidden` |
| `OPTIONS` preflight asking for an allowed method and header | `200` with `Access-Control-Allow-Methods`, `-Headers`, `-Max-Age`; the endpoint does not run |
| preflight asking for a method not in `methods` | `403` |

With `origins: ["*"]` the request's origin is echoed back and `Vary` is not sent. Put `CORS` before authentication
handlers: a preflight carries no credentials, and an authentication handler in front of `CORS` answered it with `401`.

## Handler::CSRF

```crystal
Azu::Handler::CSRF.new(
  skip_routes: ["/webhooks"],
  strategy: Azu::Handler::CSRF::Strategy::SignedDoubleSubmit,
  secret_key: ENV["CSRF_SECRET"]?,
  cookie_name: "csrf_token",
  header_name: "X-CSRF-TOKEN",
  param_name: "_csrf",
  cookie_max_age: 86_400,
  secure_cookies: true,
)
```

Requests with a method in `POST PUT PATCH DELETE` must send a token that matches the `csrf_token` cookie, in the
`X-CSRF-TOKEN` header, an `_csrf` form field or an `_csrf` query parameter. Other methods pass. A failing request
gets `403 CSRF token validation failed`. Paths that start with an entry of `skip_routes` are not checked, and
`Azu::Handler::CSRF.exempt("/exact/path")` exempts one path for every instance.

Strategies: `SignedDoubleSubmit` (default: an HMAC-signed token that expires with the cookie), `SynchronizerToken`
and `DoubleSubmit` (plain cookie comparison, not recommended).

Tokens are issued by calling `token(context)`, which also sets the cookie on that response, usually from the
endpoint that renders the form:

```crystal
struct FormPage
  include Azu::Response

  def initialize(@token : String)
  end

  def render
    %(<form method="post" action="/submit"><input type="hidden" name="_csrf" value="#{@token}"></form>)
  end
end

struct FormEndpoint
  include Azu::Endpoint(Azu::Request, FormPage)

  get "/form"

  def call : FormPage
    FormPage.new(Azu::Handler::CSRF.token(context))
  end
end
```

`Azu::Handler::CSRF.token(context)` uses `Azu::Handler::CSRF.default`. A second instance validates those tokens
only if it has the same secret: set `Azu::Handler::CSRF.secret_key = ENV["CSRF_SECRET"]` before building it (a
`CSRF.new` without one picks the shared key), or put `Azu::Handler::CSRF.default` in the chain. Checked by running
all four combinations: an instance with a different random key answered `403` to a valid token; the same key,
`200`. The `Secure` flag of the cookie is only set when `X-Forwarded-Proto` is `https`.

## Handler::Throttle

```crystal
Azu::Handler::Throttle.new(
  interval: 5,
  duration: 900,
  threshold: 100,
  blacklist: [] of String,
  whitelist: [] of String,
)
```

All five arguments are required.

- `interval` - seconds in which `threshold` requests are allowed per client address.
- `threshold` - requests allowed within `interval`; the next one blocks the client.
- `duration` - seconds a blocked client stays blocked.
- `blacklist` / `whitelist` - addresses that are always refused / never counted.

Clients are identified by the peer address of the connection (not by headers a client controls). A blocked
client gets `429` with `Retry-After` (seconds left) and an empty body. With `threshold: 3` the fourth request
in the interval was refused (`429`, `Retry-After: 2` for `duration: 3`) and `stats` reported
`{tracked_ips: 1, blocked_ips: 1}`. `reset` clears the counters. Behind a proxy every request comes from the
proxy's address; the limit then applies to all clients together.

## Handler::HealthCheck

```crystal
Azu::Handler::HealthCheck.new(
  path: "/health",
  checks: {"database" => -> { true }} of String => Azu::Handler::HealthCheck::Check,
)
```

Answers `GET` and `HEAD` on `path` without reaching the rest of the chain, with `Cache-Control: no-store`:
`200 {"status":"ok"}`, or `503 {"status":"unavailable","failing":["database"]}` naming the checks that returned
false or raised. Without checks it always answers `200`. Not in the default stack; put it before `Logger` to
keep probes out of the log.

## Handler::IpSpoofing

```crystal
Azu::Handler::IpSpoofing.new
```

Refuses with `403` a request whose `X-Client-IP` or `X-Real-IP` header names an address that is not in its
`X-Forwarded-For` list. Requests without `X-Forwarded-For` pass.

## Handler::Locale

```crystal
Azu::Handler::Locale.new
```

Picks the available locale (`Azu::Helpers::I18n.available_locales`) that best matches `Accept-Language` and
scopes it to the request with `Helpers::I18n.with_locale`. `Locale.negotiate("es,en;q=0.5", ["en", "es"], "en")`
returns `"es"`; `"pt"` matches `"pt-BR"`, `"en-GB"` matches `"en"`, `"*"` and unknown languages give the default.

## Handlers from `azu/dev`

`Handler::PerformanceMonitor` and `Handler::DevDashboard` exist only after `require "azu/dev"`; see
[Performance Design](../../explanation/architecture/performance-design.md).

## See Also

- [Core Reference](../api/core.md)
- [Handlers concept](../../explanation/concepts/middleware.md)
- [How to Create Custom Middleware](../../how-to/middleware/create-custom-middleware.md)

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
Azu::Handler::Rescuer.new(log: Log.for("Azu::Rescuer"))
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
HSTS only for sites served over HTTPS; browsers remember it. A value a header cannot carry (a line break, for one)
raises `ArgumentError` when the handler is built, not on each request.

## Handler::Static

```crystal
Azu::Handler::Static.new(
  public_dir: "public",
  fallthrough: true,
  directory_listing: false,
  cache_control: "public, no-cache",
  cache_max_age: 31_536_000,
  except: [] of String,
  mime_types: {} of String => String,
)
```

To keep template sources under `public/` from being downloaded:

```crystal
Azu::Handler::Static.new("public", except: ["/templates"])
```

- `public_dir : String` - directory to serve (default `"public"`, relative to the working directory).
- `fallthrough : Bool` - pass requests that match no file (and every method but `GET` and `HEAD`) to the next handler;
  the default is `true`. With `fallthrough: false` a missing file answers `404` and a `POST` answers `405` itself, so **no route
  behind `Static` is ever reached**: use it only for a `Static` that is the last handler.
- `directory_listing : Bool` - list directories without an `index.html`.
- `cache_control : String` - `Cache-Control` of files without a fingerprint.
- `cache_max_age : Int32` - seconds for fingerprinted files (default `config.assets.cache_max_age`, one year).
- `except : Array(String)` - paths that are never served (default none): an entry and everything below it, for example
  template sources kept in `public/templates`. A request for one falls through to the next handler (so the router
  answers its 404), or answers `404` with `fallthrough: false`; `GET`, `HEAD` and the redirect of a directory are all covered.
  Entries match whole directory names (`"/templates"` covers `/templates`, `/templates/` and `/templates/a/b.jinja`, not
  `/templates-x`); a leading slash is added and a trailing one ignored. The check runs on the decoded, normalised request
  path (`/%74emplates/x`, `//templates/x`, `/a/../templates/x`, backslashes, trailing dots and letter case included).
  Limits to know:
  - An entry is a literal path, not a URL: it is not percent-decoded.
  - Matching ignores letter case, and trailing dots and spaces, so on a case-sensitive file system `/Templates` is
    refused too (it can over-block).
  - The check is lexical and does not resolve symlinks: a symlink in `public/` that points into an excluded directory is
    served. Do not symlink into an excluded directory.
  - With `directory_listing: true` the listing of the parent still names the excluded entry (never its content).
  - An entry that resolves to the root (`""`, `"/"`, `"."`, `"/x/.."`) would exclude every path, so `new` raises `ArgumentError`.
- `mime_types : Hash(String, String)` - extra extensions to serve, for the application's own file types (see below).

### Which files are served

A file is served only when its last extension (compared in lower case) has a content type: there is no default type.
A file of any other type, or without an extension, is refused exactly like an `except` path: it falls through to the next
handler (the router answers its negotiated 404), or answers `404` with `fallthrough: false`. `GET`, `HEAD`, `Range` and
conditional requests are all refused before a header is sent, and the `except` check still runs first. A directory
listing names the files of a directory, but a request for one of unknown type is refused. `X-Content-Type-Options: nosniff`
is sent with every file.

The types are the handler's own table (`Azu::Handler::Static::MIME_TYPES`), **the same on every host**: it never reads the
operating system's `/etc/mime.types` and does not use the process-wide `MIME` registry. It holds Crystal's built-in
defaults (`.css .gif .htm .html .jpg .jpeg .js .json .pdf .png .svg .txt .xml .wasm .webp`), the fonts and source maps Azu has
always served (`.woff .woff2 .ttf .otf .sfnt .collection .map`), and these, so common assets keep working:

| Extension | Content-Type |
| --- | --- |
| `.ico` | `image/vnd.microsoft.icon` |
| `.webmanifest` | `application/manifest+json` |
| `.avif` `.bmp` `.tif` `.tiff` | `image/avif` `image/bmp` `image/tiff` |
| `.mp4` `.webm` | `video/mp4` `video/webm` |
| `.mp3` `.ogg` `.wav` `.m4a` | `audio/mpeg` `audio/ogg` `audio/wav` `audio/mp4` |
| `.csv` `.vtt` `.ics` | `text/csv` `text/vtt` `text/calendar` (UTF-8) |
| `.mjs` | `text/javascript` (UTF-8) |
| `.eot` | `application/vnd.ms-fontobject` |
| `.rss` `.atom` `.jsonld` `.xhtml` | `application/rss+xml` `application/atom+xml` `application/ld+json` `application/xhtml+xml` |
| `.zip` `.gz` `.tgz` `.tar` `.bz2` `.xz` `.7z` | `application/zip` `application/gzip` `application/x-tar` `application/x-bzip2` `application/x-xz` `application/x-7z-compressed` (downloads) |

Everything else is refused on every host, among them `.jinja .j2 .ecr .cr .yml .yaml .env .sql .db .sqlite .md .markdown
.pem .key .crt .bak .sh .py .rb .exe .dmg .apk .bin` and `.svgz` (it needs `Content-Encoding: gzip`). Opt in to any of
them with `mime_types:`. A double extension is typed by its last one: `page.jinja.html` is HTML, `page.html.jinja` is refused.

A file with no extension is refused, with one exception for ACME HTTP-01 challenges: `/.well-known/<file>` and
`/.well-known/<dir>/<file>` (such as `/.well-known/acme-challenge/<token>`) are served as `text/plain; charset=utf-8` when no
segment after `/.well-known` starts with a dot and the name does not end in a dot. Deeper paths (`/.well-known/a/b/c`) and
dot names at any level (`/.well-known/.git/config`, `/.well-known/.env`, `/.well-known/.secrets.json`, even with a
known extension) are refused, as is an extensionless file anywhere else; `/.well-known/a/b/c.json` and `/.well-known/.x.json`
are refused too (an earlier release served them), deliberately. Only the root `/.well-known/` counts, whatever the case it
is written in. An extensionless file there (`apple-app-site-association`, `openid-configuration`) is sent as `text/plain`:
an app that needs JSON names the file `.json` or answers from a route.

Files that are compressed on the fly (when the client accepts it and the file is over 860 bytes) are the text types:
`.htm .html .txt .css .js .mjs .svg .json .jsonld .xml .xhtml .csv .vtt .ics .webmanifest .rss .atom .map .eot .otf .ttf .woff .woff2`,
matched without regard to the case of the extension.

To serve a type of your own, list it. The extension is lower-cased and gets its leading dot; it is exact (no wildcard), and
the type must be a plain `type/subtype`, and two keys that are the same after that (`".Foo"` and `"foo"`) raise `ArgumentError`. It applies to this handler only and overrides a type the handler knows:

```crystal
Azu::Handler::Static.new("public", mime_types: {".heic" => "image/heic", "avifs" => "image/avif-sequence"})
```

Behaviour seen by running it:

- A file whose name carries a content hash (`app-3f2a9c1b.css`) is sent with
  `public, max-age=31536000, immutable`; every other file with `cache_control` (`public, no-cache` by default).
- Responses carry a weak `ETag` and `Vary: Accept-Encoding`; a matching `If-None-Match` answers `304`.
- `Range: bytes=0-4` answers `206` with `Content-Range`; a range past the end answers `416`.
- `GET /` serves `index.html` of the directory.
- Text files (the extensions listed under "Which files are served") larger than 860 bytes are gzip or deflate compressed
  when the client accepts it.
- Methods other than `GET` and `HEAD` answer `405` with `Allow` (or fall through).
- A `public_dir` that does not exist costs no file system calls per request (one monotonic clock read). A public dir created after boot is
  picked up within a second (the handler looks for a missing one again at most once a second); once found it is not
  checked again. With no public directory and `fallthrough: true`, a plain path (no `%`, NUL, backslash, `//`, `/.` or trailing
  slash) falls through before any path work and allocates nothing; any other path takes the full route (decode, refuse or redirect).
- With a public directory and `fallthrough: true`, a plain path whose first segment names no top-level entry of it (compared
  ignoring ASCII case; a non-ASCII segment always takes the full route) also falls through, with no file system call and no
  allocation per request. Files added below an existing entry are served at once. A new top-level file or directory is
  served from the handler's next read of the names: it looks at most once a second and reads them again when the
  directory's modification time or identity (device and inode, so a swapped `public` symlink counts) changed, and every
  60 seconds regardless. That assumes adding a name moves the directory's modification time, as local file systems do;
  a copy that keeps timestamps (`rsync -a`, `cp -a`, archives with fixed dates) or a network or FUSE file system may
  delay a new top-level name up to that minute. A directory with more than 10,000 top-level names keeps none, and every
  path takes the full route.
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

With `origins: ["*"]` the request's origin is echoed back, so the response carries `Vary: Origin`. Put `CORS` before authentication
handlers: a preflight carries no credentials, and an authentication handler in front of `CORS` answered it with `401`.

## Handler::CSRF

```crystal
Azu::Handler::CSRF.new(
  skip_routes: ["/webhooks"],
  strategy: Azu::Handler::CSRF::Strategy::SignedDoubleSubmit,
  secret_key: nil, # default: the CSRF_SECRET variable (see below)
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

`SynchronizerToken` compares the request's token with one the handler keeps in a token store. The default store is
the `csrf_token` cookie (`CSRF::CookieTokenStore`), which the client holds. `CSRF::SessionTokenStore` keeps the
token in the server-side session instead, through `Azu.session_adapter` (see
[Use Sessions](../../how-to/middleware/use-sessions.md) for the `session` shard setup):

```crystal
class AppSession
  property csrf_token : String? = nil
end

# One session per visitor, looked up from the request (here a header; a real app uses its session library)
sessions = Hash(String, AppSession).new { |hash, id| hash[id] = AppSession.new }
session_of = ->(context : HTTP::Server::Context) { sessions[context.request.headers["X-Session-Id"]? || ""] }

Azu.session_adapter = Azu::SessionAdapter.new(
  csrf_token: ->(context : HTTP::Server::Context) { session_of.call(context).csrf_token },
  store_csrf_token: ->(context : HTTP::Server::Context, token : String) { session_of.call(context).csrf_token = token; nil },
)

csrf = Azu::Handler::CSRF.new(
  strategy: Azu::Handler::CSRF::Strategy::SynchronizerToken,
  token_store: Azu::Handler::CSRF::SessionTokenStore.new,
)
```

The adapter must return the token of the session of *that request*: a single shared session object would give
every visitor the same token. Put the session handler before `CSRF` in the chain.
used by `SynchronizerToken` only; `SignedDoubleSubmit` and `DoubleSubmit` are cookie patterns by definition.
Issuing a token without an adapter raises `Azu::SessionAdapter::NotConfigured`; validating a request when the
adapter or the session is unavailable answers `403`. An empty stored token counts as none.

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

Without `secret_key:` the handler signs with the `CSRF_SECRET` variable (`Azu::Env.secret("CSRF_SECRET")`). When it is
not set, the handler uses a random key that only this process knows (one warning in the log) outside production, and
**raises `Azu::Env::MissingError` when it is built in production** (or any `Azu::Env.strict_environments`): tokens signed
with a per-process key are rejected after a restart and by every other server.

`Azu::Handler::CSRF.token(context)` uses `Azu::Handler::CSRF.default`. A second instance validates those tokens
only if it has the same secret: set `CSRF_SECRET` (or `Azu::Handler::CSRF.secret_key = ...` before building it), or put
`Azu::Handler::CSRF.default` in the chain. Checked by running
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
[Performance Design](../../explanation/architecture/performance-design.md). `DevDashboard` serves in the development
environment only: elsewhere it passes every request to the next handler, and building it logs a warning
([Environments](../configuration/environments.md#what-depends-on-the-environment)).

## See Also

- [Core Reference](../api/core.md)
- [Handlers concept](../../explanation/concepts/middleware.md)
- [How to Create Custom Middleware](../../how-to/middleware/create-custom-middleware.md)

---
description: "Every middleware handler Azu ships in `Azu::Handler`: what it does, its options and where it goes in the chain."
---

# Built-in handlers

Azu ships handlers for the common middleware needs. They are all `HTTP::Handler`s in the `Azu::Handler`
namespace, come with `require "azu"` (except those of `azu/dev`), and are used the same way: build them, put them in
the array given to `start`. They are not routes: a handler sees every request, before the router.

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

## API

### Writing a handler

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

### Default stack

`Azu::App#default_handlers` builds fresh instances of:

| Handler | As configured by default |
|---|---|
| `RequestId` | header `X-Request-ID` |
| `Logger` | `config.log` |
| `Rescuer` | |
| `SecurityHeaders` | `hsts: config.tls?` |
| `Static` | `./public`, `fallthrough: true` |

### Handler::RequestId

```crystal
Azu::Handler::RequestId.new(header_name: "X-Request-ID")
```

Keeps the request id the client sent, or generates `req_<unix ms>_<hex>`. The id is written to the request and
response headers, and `Azu::RequestContext.current?.try(&.request_id)` returns it anywhere in the request's fiber
(logs, database instrumentation). Put it first.

`Azu::RequestContext.current?` returns an `Azu::RequestContext::Info`, or `nil` outside a request:

| Field | Type | Value |
|---|---|---|
| `request_id` | `String` | The request id |
| `method`, `path` | `String` | The request's method and path |
| `endpoint` | `String?` | The endpoint's type name, once an endpoint serves the request |
| `fiber_id` | `UInt64` | The `object_id` of the fiber the context belongs to |
| `http_context` | `HTTP::Server::Context?` | The request being served; `nil` for a context opened with `with` |

An endpoint opens the context too when no `RequestId` did (with an id of its own). Work that runs outside a request,
a background job or a spec, opens one with `RequestContext.with`, so its logs and queries are tagged the same way:

```crystal
require "azu"

Azu::RequestContext.with("job-42", "POST", "/jobs/mail", endpoint: "MailJob") do
  Azu::RequestContext.current?.try(&.request_id) # => "job-42"
end
```

`with(request_id, method = "GET", path = "/", endpoint = nil, &)` restores the context the fiber had before when the
block ends.

### Handler::Logger

```crystal
Azu::Handler::Logger.new(log: Log.for("http"))
```

- `log : ::Log?` - where lines go. Without one, the log of the app serving the request (`Azu.current_config.log`,
  the `Azu` source unless the app sets `config.log`).

Logs one `Info` line per request after the rest of the chain has run:

```text
127.0.0.1 ⤑ GET Path: /ok Endpoint: OkEndpoint Status: 200 Latency: 90.49µs
```

The endpoint is `unknown` when no route matched. Because it logs after `call_next`, a `Logger` placed outside
`Rescuer` reports the status the client got (a request that raised is logged with `Status: 500`). There are no
options to skip paths. See [Add logging](../../how-to/middleware/add-logging.md).

### Handler::SimpleLogger

```crystal
Azu::Handler::SimpleLogger.new(log: Log.for("http"))
```

An alternative to `Logger` that reports through Azu's asynchronous logging pipeline: the line is written from a
spawned fiber after the request, at info for 2xx/3xx, warn for 4xx and error for 5xx, with method, path, endpoint,
status, latency, remote address, user agent and content length as fields. It also copies the request id into
`X-Request-ID`. Without `log:` it logs to the app serving the request (`Azu.current_config.log`), as `Logger` does.
Use one of `Logger` and `SimpleLogger`, not both.

### Handler::Rescuer

```crystal
Azu::Handler::Rescuer.new(log: Log.for("Azu::Rescuer"))
```

Catches what the handlers after it, the router and the endpoint raise and answers with an error response.

| Raised | Status |
|---|---|
| `Response::NotFound` | 404 |
| `Response::BadRequest` | 400 |
| `Response::AuthenticationError` | 401 |
| `Response::AuthorizationError`, `Response::Forbidden` | 403 |
| `Response::NotAcceptable` | 406 |
| `Response::TimeoutError` | 408 |
| `Response::PayloadTooLarge` | 413 |
| `Response::ValidationError` | 422 |
| `Response::RateLimitError` | 429 |
| `Response::DatabaseError` | 500 |
| `Response::ExternalServiceError` | 502 |
| any other `Response::Error` | its `status` |
| any other exception | 500 |

`HTTP::Server::ClientError` (the peer went away) is logged at debug level and not answered. `Rescuer` sees only
what is raised inside an endpoint's `call` and the handlers after it. A request that breaks its contract never
reaches `call`: the endpoint answers it itself, `400` when the body or a field cannot be read as the contract's
types, `413` when it is over `upload.max_file_size`, and `422` with the failing fields when a validation rule fails,
so `Rescuer` never sees it. The
router answers an unrouted path with `404` itself, and a negotiated endpoint answers `406` itself.

The body is chosen by the first media type of the `Accept` header: JSON, HTML, XML or plain text, and plain text
without a header or with `*/*`. In development the error includes the request context, HTML clients receive
Azu's exception page and JSON clients an `exception` member with the same triage (see
[Debug exceptions](../../how-to/errors/debug-exceptions.md)); a server error is also reported to
`Instrumentation.on_exception` subscribers, so the dev dashboard keeps it. In any other environment the context is
`null` and HTML clients get the `error.html` template (the app's own, or Azu's built-in one), an unexpected exception
included: a `500` page titled `500 · Internal Server Error` that does not show the exception's message.
Without `Rescuer`, an exception reaching Crystal's server becomes a bare `text/plain` `500 Internal Server Error`
and a stack trace in the log.

### Handler::SecurityHeaders

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
(`hsts: true`). A header the application already set is left alone, so one endpoint can loosen a policy. A value a
header cannot carry (a line break, for one) raises `ArgumentError` when the handler is built, not on each request.

{% hint style="warning" %}
Enable HSTS only for sites served over HTTPS; browsers remember it.
{% endhint %}

### Handler::Static

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
defaults (`.css .gif .htm .html .jpg .jpeg .js .json .pdf .png .svg .txt .xml .wasm .webp`), fonts and source maps
(`.woff .woff2 .ttf .otf .sfnt .collection .map`), and these:

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
are refused too. Only the root `/.well-known/` counts, whatever the case it is written in. An extensionless file there (`apple-app-site-association`, `openid-configuration`) is sent as `text/plain`:
an app that needs JSON names the file `.json` or answers from a route.

Files that are compressed on the fly (when the client accepts it and the file is over 860 bytes) are the text types:
`.htm .html .txt .css .js .mjs .svg .json .jsonld .xml .xhtml .csv .vtt .ics .webmanifest .rss .atom .map .eot .otf .ttf .woff .woff2`,
matched without regard to the case of the extension.

To serve a type of your own, list it. The extension is lower-cased and gets its leading dot; it is exact (no wildcard), and
the type must be a plain `type/subtype`, and two keys that are the same after that (`".Foo"` and `"foo"`) raise `ArgumentError`. It applies to this handler only and overrides a type the handler knows:

```crystal
Azu::Handler::Static.new("public", mime_types: {".heic" => "image/heic", "avifs" => "image/avif-sequence"})
```

Other behavior:

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
  ignoring ASCII case and trailing dots; a non-ASCII segment always takes the full route, and so does every path when a
  top-level name is not ASCII) also falls through, with no file system call and no allocation per request. Files added below an existing entry are served at once. A new top-level file or directory is
  served from the handler's next read of the names: it looks at most once a second and reads them again when the
  directory's modification time or identity (device and inode, so a swapped `public` symlink counts) changed, and every
  60 seconds regardless. That assumes adding a name moves the directory's modification time, as local file systems do;
  a copy that keeps timestamps (`rsync -a`, `cp -a`, archives with fixed dates) or a network or FUSE file system may
  delay a new top-level name up to that minute. A directory with more than 10,000 top-level names keeps none, and every
  path takes the full route.
- A file in `public/` shadows a route with the same path, so keep only public files there.

### Handler::Compression

```crystal
Azu::Handler::Compression.new
```

The standard library's `HTTP::CompressHandler`: gzip or deflate for clients that send `Accept-Encoding`. It is not
in the default stack. `Static` already compresses and sets its own length, so place `Compression` after `Static`.

### Handler::CORS

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
- `headers` - request headers a preflight may ask for (default `Accept Content-Type X-CSRF-TOKEN`, so a
  session-cookie API behind `Handler::CSRF` works without more).
- `credentials : Bool` - send `Access-Control-Allow-Credentials: true`. It cannot be combined with `"*"` in `origins`:
  `CORS.new` (and the `origins=` / `credentials=` setters) raise `ArgumentError`, because a handler that echoed every origin
  with credentials would let any site read a signed-in user's responses. List the origins instead.
- `max_age : Int32?` - `Access-Control-Max-Age` of preflights.
- `expose_headers`, `vary` - extra `Access-Control-Expose-Headers` / `Vary` content.

With the allowed origin `https://app.example.com`:

| Request | Result |
|---|---|
| `GET` without `Origin` | passes through, no CORS headers |
| `GET` from the allowed origin | `200` with `Access-Control-Allow-Origin` set to that origin and `Vary: Origin` |
| `GET` from another origin | `403 Forbidden` |
| `OPTIONS` preflight asking for an allowed method and header | `200` with `Access-Control-Allow-Methods`, `-Headers`, `-Max-Age`; the endpoint does not run |
| preflight asking for a method not in `methods` | `403` |

With `origins: ["*"]` (and no credentials) the response carries the literal `Access-Control-Allow-Origin: *`. `Vary: Origin`
is sent whenever the answer depends on the request's `Origin` (always, with or without the header), so a shared cache
keeps one entry per origin.

How an `Origin` is matched:

- A regex must match the **whole** `Origin`: it is wrapped in `\A(?:...)\z`, so `/good\.com/` allows `https://good.com`
  only, not `https://good.com.evil.test` or `https://evilgood.com` (a search would have). Write the scheme into it:
  `/https:\/\/[a-z0-9-]+\.example\.com/` for any one-label subdomain. The `x` flag works, trailing `# comment` included; an inline `(?x)` ending in a comment, without the flag, does not (it raises `ArgumentError` when the handler is built).
- `origins` returns a copy: change the list with `cors.origins = [...]` (it re-checks the wildcard and credentials rule), not
  with `cors.origins << "https://b.test"`, which changes nothing.
- A listed string must equal it exactly, and it is case-sensitive (browsers send the scheme and host in lower case): a
  subdomain, another port, another scheme, a trailing slash or a path does not match.
- A value that is not `scheme://host[:port]` matches nothing, not even a regex: a path, userinfo (`@`), whitespace or control
  characters, a comma-joined value, and several `Origin` (or `X-Origin`) headers are all refused with `403`. `X-Origin` is only
  read when there is no `Origin`.
- `Origin: null` (sandboxed frames, `file:` pages, some redirects) is any page's to send, so it matches only when the string
  `"null"` is listed in `origins`: never `"*"` and never a regex. **`origins: ["null"], credentials: true` lets every
  sandboxed iframe and `data:` page read credentialed responses: do not.**
- A preflight is allowed only when **every** header in `Access-Control-Request-Headers` is in `headers` (compared without
  regard to case); one allowed header no longer carries the others. `Access-Control-Allow-Headers` lists them in the order
  asked and in the spelling of `headers`, not as the request wrote them. A preflight without `Access-Control-Request-Headers` (a
  bare cross-origin `DELETE`) is decided by origin and method alone and gets no `Access-Control-Allow-Headers`. Anything
  refused gets no `Access-Control-*` header. A preflight response varies by `Origin`, `Access-Control-Request-Method` and `Access-Control-Request-Headers`. A preflight is an `OPTIONS` request with an `Access-Control-Request-Method`
  header; an `OPTIONS` request without one is an ordinary request and goes to the next handler, with the origin's
  `Access-Control-Allow-Origin` (a listed origin) or `403` (any other).

{% hint style="warning" %}
Put `CORS` before authentication handlers: a preflight carries no credentials, so an authentication handler in front
of `CORS` answers it with `401`.
{% endhint %}

### Handler::CSRF

```crystal
Azu::Handler::CSRF.new(
  skip_routes: ["/webhooks"],
  strategy: Azu::Handler::CSRF::Strategy::SignedDoubleSubmit,
  secret_key: nil, # default: the CSRF_SECRET variable (see below)
  cookie_name: "csrf_token",
  header_name: "X-CSRF-TOKEN",
  param_name: "_csrf",
  cookie_max_age: 86_400,
  cookie_same_site: HTTP::Cookie::SameSite::Strict,
  secure_cookies: true,
  token_store: nil, # SynchronizerToken only; default: CSRF::CookieTokenStore
  check_origin: true,
)
```

- `cookie_same_site : HTTP::Cookie::SameSite` - the `SameSite` attribute of the token cookie (default `Strict`).
  The cookie is also `HttpOnly` and has `Path=/`.
- `token_store : CSRF::TokenStore?` - where `SynchronizerToken` keeps the token (see below).
- `defer_secret : Bool` - with `true` the secret is not read until the first token is signed or checked; the
  default reads it when the handler is built. A secret shorter than 32 bytes is logged as a warning when it is read.
- `check_origin : Bool` - whether a request that names its origin must come from this app's own (see below; default
  `true`).
- `log : Log` - where the handler's warnings go (default `Log.for("Azu::Handler::CSRF")`).

Requests with a method in `POST PUT PATCH DELETE` must send a token that matches the `csrf_token` cookie, in the
`X-CSRF-TOKEN` header or an `_csrf` form field; a token in the query string is ignored (a URL is logged, kept in the
browser history and sent as a `Referer`). Other methods pass. A failing request
gets `403 CSRF token validation failed`. Paths that start with an entry of `skip_routes` are not checked, and
`Azu::Handler::CSRF.exempt("/exact/path")` exempts one path for every instance.

Before the token, a request that carries an `Origin` header (or, without one, a `Referer`) must come from the origin
the app is served under, as `CSRF.validate_origin` judges it, or the answer is `403 CSRF origin check failed` and the
body is not read. Browsers send `Origin` with every cross-site `POST`, so this refuses a forged request even when its
token is valid (a token cookie planted from a sibling subdomain, say). A request that names no origin, from an API
client or `curl`, is checked by its token alone, and so is one from an origin that an `Azu::Handler::CORS` earlier in
the chain lists and allowed (it marks the request: `HTTP::Request#cors_allowed?`; a `*` wildcard vouches for nobody).
Behind a proxy that rewrites `Host`, make it forward `X-Forwarded-Host`, and `X-Forwarded-Proto` if it terminates
TLS; the proxy must overwrite both, since the check trusts them. Without `X-Forwarded-Proto` and without TLS of its
own the app cannot tell its scheme and accepts its host under `http` or `https`. An `Origin: null` names no origin and
is refused: a page served with `Referrer-Policy: no-referrer` sends it with its own forms, so such an app passes
`check_origin: false`.

Where the form token is looked for, and how much of the body is read for it:

- A token in the `X-CSRF-TOKEN` header is checked first and the body is not touched. Without a token cookie, or (with
  the default `SignedDoubleSubmit` only) with one this handler did not sign, the request is refused before its body is
  read. With `DoubleSubmit`, or `SynchronizerToken` on the cookie store, the cookie is whatever the client sent and
  cannot be checked first: the body is read (within the limits below) before the `403`.
- `application/x-www-form-urlencoded` (the media type is matched whatever its case): the body is read up to
  `max_form_size` (1 MB by default; `upload.max_file_size` when that is smaller) and parsed for the field. A
  `Content-Length` over the limit, or a body (chunked, say) that turns out longer, is answered with
  `413 Payload Too Large` and `Connection: close`, after reading at most the limit plus one byte. Raise `max_form_size`
  for forms that post more, such as a large textarea: `Azu::Handler::CSRF.default.max_form_size = 5_000_000_u64`, the
  `max_form_size:` argument of `CSRF.new`, or the `CSRF_MAX_FORM_SIZE` environment variable (bytes) for every handler.
- `multipart/form-data`: the parts are walked once, front to back, over the first 64 KB (`CSRF::MULTIPART_SCAN_LIMIT`)
  at most, reading only as far as needed (a client that sends the token part and then stalls is not waited for).
  **The `_csrf` field must be one of the first 64 parts, before the first file part, and end within those 64 KB.** A
  part with a `filename` is a file part, and that includes the empty file input a browser sends as
  `filename=""` when nothing is chosen. Put `csrf_field()` at the top of the form, above every file input. A token after
  a file, past 64 parts or 64 KB, in a part whose `name` or `filename` is repeated, or in a request without a
  `boundary` is not found, and the request is refused with `403`. `CSRF` does not check the size
  of a multipart body: the endpoint does, while it streams it in (`upload.max_request_size`, `max_parts`, `max_files` and
  `max_file_size` per file; see [Handle file uploads](../../how-to/file-handling/handle-file-uploads.md)).
- In every case the endpoint still reads the whole body afterwards, as it was sent.

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

Azu::Handler::CSRF.configure do |csrf|
  csrf.strategy = Azu::Handler::CSRF::Strategy::SynchronizerToken
  csrf.token_store = Azu::Handler::CSRF::SessionTokenStore.new
end
# then put Azu::Handler::CSRF.default in the handler chain
```

{% hint style="danger" %}
The adapter must return the token of the session of *that request*: a single shared session object would give
every visitor the same token.
{% endhint %}

Put the session handler before `CSRF` in the chain.
The token store is used by `SynchronizerToken` only; `SignedDoubleSubmit` and `DoubleSubmit` are cookie patterns by
definition.
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

The cookie is set with `Path=/`, so a token issued on one page reaches every path its form may post to (`GET /auth/login`,
then `POST /session`). Earlier versions set no `Path`, and browsers kept the cookie for the directory of the page that
issued it only (`/auth`), so such a form was refused with `403`. A browser can hold an old cookie like that next to the new
one until it expires (`cookie_max_age`); a request inside its directory then carries both, the longer path first, and the
handler reads the last cookie of the name, the `Path=/` one. `SignedDoubleSubmit` and `DoubleSubmit` set a new cookie with
every token, so they work from the first page rendered after the upgrade. `SynchronizerToken` with the cookie store reuses
the token a request already carries and sets no cookie: a browser that holds only an old cookie keeps its token, and a form
posting outside that cookie's directory is refused, until the cookie expires or a page outside the directory issues a new
token. Nothing needs to be done; see [Breaking Changes](../breaking-changes.md).

Without `secret_key:` the handler signs with the `CSRF_SECRET` variable (`Azu::Env.secret("CSRF_SECRET")`). When it is
not set, the handler uses a random key that only this process knows (one warning in the log) outside production, and
**raises `Azu::Env::MissingError` when it is built in production** (or any `Azu::Env.strict_environments`): tokens signed
with a per-process key are rejected after a restart and by every other server.

`Azu::Handler::CSRF.token(context)` uses `Azu::Handler::CSRF.default`, and so do the template variables
(`csrf_token`, `csrf_tag`, `csrf_metatag`), the form helpers and an endpoint's `csrf_token`. A second call for the same
response (on any instance) returns the token already issued for it: the response's CSRF cookie, or the session's with
`SessionTokenStore`. So every form and meta tag of one page carries the same token; a deleted, expired or other-path
cookie is replaced. A second instance
validates those tokens only if it has the same secret, strategy and token store: configure `CSRF.default` (with
`CSRF.configure`) and put it in the chain, or at least set `CSRF_SECRET` (or `Azu::Handler::CSRF.secret_key = ...`
before building the other instance). An instance with a different key, or a `SynchronizerToken` instance next to a
default that signs, answers `403` to a token the page carries. The `Secure` flag of the cookie is set when the request
came over TLS: `X-Forwarded-Proto: https` from a proxy, or this server terminating TLS itself (`config.tls?`).

`token(context)` returns the token already set on this response's cookie when there is one, so every field, tag and
meta tag of a page carries the same token. The class methods act on `CSRF.default`:

| Method | Returns | Notes |
|---|---|---|
| `CSRF.default` | `CSRF` | The shared instance, built on first use |
| `CSRF.configure(&)` | the block's value | Yields `default` (built with `defer_secret: true`), then reads its secret, so a production app without one fails here, at boot |
| `CSRF.token(context)`, `CSRF.tag(context)`, `CSRF.metatag(context)` | `String` | The token; `<input type="hidden" name="_csrf" value="..." />`; `<meta name="_csrf" content="..." />` (the name is `param_name`) |
| `CSRF.validate_origin(context)` | `Bool` | Whether `Origin` (without it, the origin of `Referer`) is `<scheme>://<host>`, where the scheme is the first `X-Forwarded-Proto`, else `https` when the app serves TLS, else `http`, and the host is the first `X-Forwarded-Host`, else `Host`. Scheme and host compare ignoring case, and a default port matches whether it is written or not. `false` without a host, or without both `Origin` and `Referer`. `call` runs it for every state-changing request that names an origin (`check_origin`) |
| `CSRF.use_signed_double_submit!`, `use_synchronizer_token!`, `use_double_submit!` | `Strategy` | Set the strategy of `default` |
| `CSRF.strategy`, `secret_key`, `cookie_name`, `header_name`, `param_name`, `cookie_max_age`, `secure_cookies` | | Read and write (`=`) the settings of `default`; `secret_key=` also applies to instances built afterwards without a key |
| `CSRF.exempt(path : String)` | `Nil` | Exempts one exact path for every instance |
| `CSRF.in_use?` | `Bool` | True once any `CSRF` was built in the process; templates get `csrf_token`, `csrf_tag` and `csrf_metatag` only then |

```crystal
require "azu"

Azu::Handler::CSRF.configure do |csrf|
  csrf.cookie_same_site = HTTP::Cookie::SameSite::Lax
end
```

### Handler::Throttle

```crystal
Azu::Handler::Throttle.new(
  interval: 5,
  duration: 900,
  threshold: 100,
  blacklist: [] of String,
  whitelist: [] of String,
  log: Log.for("throttle"),
  trusted_proxies: ["10.0.0.0/8", "::1"],
  ipv6_prefix: 64,
  max_clients: 100_000,
)
```

The first five arguments are required.

- `interval` - seconds in which `threshold` requests are allowed per client address.
- `threshold` - requests allowed within `interval`; the next one blocks the client.
- `duration` - seconds a blocked client stays blocked.
- `blacklist` / `whitelist` - addresses and CIDR blocks that are always refused / never counted.
- `log : ::Log?` - where blocks, releases and refusals are logged (at most 10 refusals a second, then one line
  counting the rest). Without one, the log of the app serving the request.
- `trusted_proxies : Array(String)` - the reverse proxies in front of the app, as exact IPv4 or IPv6 addresses and CIDR
  blocks (`"10.0.0.0/8"`, `"fd00::/8"`, `"203.0.113.7"`, `"::1"`); an entry that is neither, or a catch-all block, raises
  `ArgumentError`. Empty by default: the client is the address of the connection, as before.
- `ipv6_prefix : Int32` - IPv6 clients are counted by their first N bits, 64 by default: a subscriber owns a whole /64
  and could otherwise dodge the limit, and fill the table, by rotating the rest.
- `max_clients : Int32` - the most clients tracked at once, 100 000 by default.

Clients are identified by the peer address of the connection (not by headers a client controls). A blocked
client gets `429` with `Retry-After` (seconds left) and the body of a `Response::RateLimitError`, chosen by `Accept`
like every [error response](../errors/error-types.md#error-response-format): with `threshold: 3` the fourth request in
the interval answers `429`, and a JSON client gets
`{"type":"about:blank","title":"Rate Limit Exceeded","status":429,"detail":"Rate limit exceeded. Retry after 899 seconds.",...}`.
`stats` returns `{tracked_ips: Int32, blocked_ips: Int32}`, and `reset` clears the counters.

Outside development, the HTML page of a refusal is rendered once a second for each `Retry-After` value and locale,
and served to every client refused in that second, with the same `X-Error-ID`. A custom `error.html` must therefore
not depend on the request (no path, user or token in it): what it renders for one client is shown to others.

#### Behind a reverse proxy

Without `trusted_proxies`, every request behind a proxy comes from the proxy's address and the limit applies to all
clients together. List the proxies and `Throttle` reads `X-Forwarded-For` for the requests that come from them:

```crystal
Azu::Handler::Throttle.new(
  interval: 5, duration: 900, threshold: 100,
  blacklist: [] of String, whitelist: [] of String,
  trusted_proxies: ["10.0.0.0/8"],
)
```

- Only when the connection's peer is a trusted proxy is the header read; from any other peer it is ignored, so a client
  cannot pick its key by sending it.
- All `X-Forwarded-For` lines are read as one list, in order, from the **right**: past the trusted proxies, the first
  address that is not trusted is the client (a proxy appends the address it saw; whatever stands left of that was
  written by the client). The left-most address is never used.
- Entries may carry whitespace, a port (`1.2.3.4:5678`, `[2001:db8::1]:443`) or be IPv4-mapped (`::ffff:1.2.3.4`, the
  same client as `1.2.3.4`). A header that names no client (an entry that is not an address such as `unknown`, a
  name, a zone id, a bad port or leading zeros; a chain with only trusted hops; a chain over 32 hops) is never guessed
  at: the request is counted under the proxy's address with `!forwarded` added, a bucket of its own. A request
  that carries no header at all (the proxy's own health check) stays under the proxy's address. So whoever makes a
  proxy forward garbage fills and blocks only that bucket, and cannot get the proxy's own requests refused. The
  lists are not consulted for such a request: whitelisting the proxy does not exempt it.
- `blacklist` and `whitelist` take addresses and CIDR blocks of both families (an entry that is neither raises
  `ArgumentError` when the handler is built) and are matched against the client so found, in any spelling of the
  address. Whitelisting a proxy therefore does not whitelist its clients; to exempt the load balancer's health checks
  whitelist the balancer's address (requests without `X-Forwarded-For` are the balancer itself) or answer them
  before `Throttle`, as `HealthCheck` does.
- A catch-all entry in `trusted_proxies` (`0.0.0.0/0`, `::/0`, or any `/0`) raises `ArgumentError`: it would make every
  client a proxy and the header theirs to write. List only ranges that clients cannot reach directly. Two halves
  (`0.0.0.0/1` and `128.0.0.0/1`) together are not detected as a catch-all, and are as wrong. `blacklist` and `whitelist`
  accept `0.0.0.0/0` and `::/0` on purpose (refuse or exempt everything). An IPv4-mapped entry takes an IPv4 prefix
  length (`::ffff:10.0.0.0/8`, not `/104`).
- A server listening on a UNIX socket has no peer address to compare: `trusted_proxies` never matches there, the
  header is ignored and every client is counted as one. Listen on TCP (loopback is enough: `"127.0.0.1"`, `"::1"`),
  or rate-limit in the proxy.

How the proxies append the address:

| Proxy | What to configure | What to trust |
|---|---|---|
| nginx | `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` | the address nginx connects from (`127.0.0.1` on the same host) |
| AWS Application Load Balancer | nothing: it appends the peer address | the subnets of the load balancer's network interfaces, not the VPC at large |
| Cloudflare in front of your own proxy | keep the header | your own proxy **and** Cloudflare's published ranges |
| Envoy | `use_remote_address: true` on the HTTP connection manager (it makes Envoy append the peer address; `xff_num_trusted_hops` only says how many hops to skip when it does not) | the proxy's own address |
| HAProxy | `option forwardfor` | the proxy's own address |

Cloudflare's ranges change: take them from Cloudflare's published list when you deploy and refresh them on a schedule;
the framework does not ship them. Never trust a range that clients can reach directly (a public address, an open
security group), because a request from there may carry any `X-Forwarded-For`. The proxy must append to or
replace the header, not pass the client's value on as the last hop.

`Handler::IpSpoofing` is a different check, not a source of the client: it refuses a request whose `X-Client-IP` or
`X-Real-IP` is not in its own `X-Forwarded-For`. It does not decide who the client is and it trusts nothing; `Throttle`
does not use it, and it can stand in front of `Throttle` to drop requests whose forwarding headers contradict each other.

#### IPv6 and `ipv6_prefix`

A client is counted by the first `ipv6_prefix` bits of its address (64 by default): one subscriber, one cloud instance
or one hosting account usually holds a whole /64 and can use any address in it, so counting single addresses would let
it dodge the limit and fill the table. Lower it (`56`, `48`) when attackers come from networks that hand out a /56 or
/48 per customer; raise it (`128`) only for a network where unrelated clients share a /64 (some VPC subnets and shared
hosting), at the price of the dodge above. IPv4 clients are always counted by address.

#### Memory

The table of clients is swept for trackers whose window has ended, and for blocks that have ended, on a request, at most
once a second (no fiber, on `Azu::Clock`); a sweep of a full table takes a few milliseconds. Clients inside their window
and blocked clients are kept in two tables, each in the order clients entered it, so making room is O(1) however many
clients are blocked. Past `max_clients` a new client takes the place of the client first seen longest ago that is not
blocked; only when every tracked client is blocked does it take the place of the block that ends first. A
flood of addresses therefore cannot grow the table, and it cannot lift a block while an unblocked tracker exists. That
holds only for the moment: once the table is full of blocks, each fresh address that blocks itself (`threshold` + 1
requests) takes the place of the block that ends first, so blocks are released first in, first out at the rate the
attacker can mint blocked addresses. The price is that a flood of more than `max_clients` distinct clients (one attacker with a /48, say) pushes the others'
counters out and they start from zero: raise `max_clients` where that matters, and lower `ipv6_prefix` for such
attackers. Each tracked client costs roughly 180 to 220 bytes. Blocks and releases are logged at most `LOG_PER_SECOND`
(10) a second, then one line says how many were left out, like the refusals.

### Handler::HealthCheck

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

### Handler::IpSpoofing

```crystal
Azu::Handler::IpSpoofing.new
```

Refuses with `403` a request whose `X-Client-IP` or `X-Real-IP` header names an address that is not in its
`X-Forwarded-For` list. Requests without `X-Forwarded-For` pass. It is a consistency check: who the client is behind a
proxy is decided by [`Throttle`'s `trusted_proxies`](#handlerthrottle), not here.

### Handler::Locale

```crystal
Azu::Handler::Locale.new
```

Picks the available locale (`Azu::Helpers::I18n.available_locales`) that best matches `Accept-Language` and
scopes it to the request with `Helpers::I18n.with_locale`. `Locale.negotiate("es,en;q=0.5", ["en", "es"], "en")`
returns `"es"`; `"pt"` matches `"pt-BR"`, `"en-GB"` matches `"en"`, `"*"` and unknown languages give the default.

### Handlers from `azu/dev`

`Handler::PerformanceMonitor` and `Handler::DevDashboard` exist only after `require "azu/dev"`; see
[Performance Design](../../explanation/architecture/performance-design.md). `DevDashboard` serves in the development
environment only: elsewhere it passes every request to the next handler, and building it logs a warning
([Environments](../configuration/environments.md#what-depends-on-the-environment)).

## Limits

- `Throttle` counts in the process: several processes each keep their own counters.

## See also

- [App](../api/app.md)
- [Handler pipeline](../api/handler-pipeline.md)
- [Middleware](../../explanation/concepts/middleware.md)
- [Create custom middleware](../../how-to/middleware/create-custom-middleware.md)

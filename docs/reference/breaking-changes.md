---
description: The breaking changes between Azu versions, and how to migrate across each one.
---

# Breaking changes

Every change merged to `master` is released: as a patch version by default, as a minor one when its commit message
carries `(MINOR)` (0.6.0, 0.7.0, 0.8.0 and 0.9.0 did), so each change is listed under the first release that shipped it,
newest first; a release that shipped a breaking change as a patch says so in its entry. Changes that are merged but not
released yet are under [Next release](#next-release). [Migrate to 0.6](../how-to/migrate-to-0.6.md) walks an application
from an early 0.5 release to the current API, with old and new code side by side; every release is tagged on
[GitHub](https://github.com/azutoolkit/azu/releases).

## Next release

**The development exception page is Azu's own, and the `exception_page` shard is gone** (released as a minor version).
`Azu::ExceptionPage` no longer inherits from the shard's `::ExceptionPage`, so its `styles` override and the shard's
other methods are gone; `ExceptionPage.redacted(context, exception).to_s` still renders the page. The page triages the
exception (where the app raised it, likely causes, the request's queries and the endpoint's history) and the dev
dashboard has an **Errors** tab that keeps every server error; see [Debug exceptions](../how-to/errors/debug-exceptions.md).
An app that required `exception_page` through Azu adds the shard to its own `shard.yml`. In development the JSON problem
body gains an `exception` member and the text body starts with the triage; production bodies are unchanged.

**The built-in `error.html` and `error_debug.html` are redesigned.** They take the same data, but `error.html` no longer
prints `source` or `fingerprint`, prints `detail` and `errors` for a status below 500 only, and loads no web font. An app
whose own `error.html` overrides Azu's is not affected.

**`DevDashboard` UI files moved.** `widgets.cr`, `status.cr`, `format.cr`, `dashboard.css`, `theme_boot.js` and
`icons.svg` moved from `src/azu/dev/dev_dashboard/` to `src/azu/ui/`, shared with the exception page; their module names
are unchanged.

## 0.9.1

**An `IO::TimeoutError` that is not the client's is now a `500`, not a `408`** (#261, released as a patch). `Rescuer`
answers `408` only for `Azu::ServerLimits::ClientTooSlow`, which the reads and writes of a limited connection raise when the
client is too slow; any other `IO::TimeoutError` (an upstream HTTP client, Redis or a database timing out) is the server's
failure, answered `500` and logged with its backtrace. Code that raised `IO::TimeoutError` to answer `408` raises
`Azu::ServerLimits::ClientTooSlow` instead.

## 0.9.0

**The server limits of 0.8.1 also run on HTTPS, and their configuration is stricter** (#258, the release that carries the
`(MINOR)` marker the limits lacked in 0.8.1). The rules now run on HTTPS connections, on the decrypted request, with the TLS
handshake inside `header_timeout`; a connection over `max_connections` on a TLS port is closed without a `503`. A timeout of `0`
or less switches that wait off, and a `SERVER_*` value that is not a number is logged and the default kept. The default
`max_connections` is the open-file limit less 256 when that is below 10 000. A request body the client stops sending raises in
the handler's read and `Rescuer` answers `408` with one log line. An upload sent with `Expect: 100-continue` is no longer cut by
`header_timeout`.

**Typed `Azu::Testing::Client` calls answer `TypedResponse(T)` instead of `Response`** (#259, first released in 0.9.0,
though its own commit carries no `(MINOR)` marker). A call such as `client.post(CreateUserEndpoint, NewUserRequest.new("Ada"))` returns an `Azu::Testing::TypedResponse(T)`, `T` being the
endpoint's response type: every method of `Response` still works on it and `value` decodes the body as `T`. Code that stores
the result in a variable or argument typed `Azu::Testing::Response` takes `.response`. Calls on a plain `Routable` still
answer a `Response`.

## 0.8.1

**The server cuts slow connections and caps their number** (#256; released as a patch, without the `(MINOR)` marker: read
it as a minor-release change). `App#start` bound a plain `HTTP::Server` listener: a client could hold a connection open for
ever by sending a header byte at a time, never finishing a body, or never sending anything, and the number of connections was
unbounded. The accepted sockets now carry the new `config.limits`: `header_timeout` 10 s (answered `408` over plain HTTP; from
0.9.0 a TLS connection is just closed), `read_timeout` 30 s with a `min_body_rate` of 1 KB/s after it, `write_timeout` 60 s,
`keep_alive_timeout` 60 s and `max_connections` 10 000 (the next connection gets `503`). WebSockets are exempt once upgraded.
An app that takes uploads over a very slow link, or a stream that waits on the client for more than 30 s, raises the matching
limit; `SERVER_*` variables set them. A server you bind yourself (`server.bind_tcp`) is unchanged; use
`Azu::ServerLimits.bind_tcp` to give it the same limits. 0.9.0 extends the rules to HTTPS (see above).

**`Templates.compile` is gone.** The compiled-templates milestone of 0.7.1 (#254) was reverted (#257): a build that calls
the `Azu::Templates.compile` macro or `Templates#compiled=` no longer compiles. Templates render through Crinja, as before
0.7.1.

## 0.8.0

**Multipart uploads have request-wide limits, and temp files are private and removed after the request.** `upload.max_file_size`
bounded each file only, so a client could stream any number of files of up to 10 MB each. New `upload.max_request_size` (64 MB,
`UPLOAD_MAX_REQUEST_SIZE`), `max_parts` (100) and `max_files` (20) are enforced while the body streams (and a `Content-Length` over
the first is refused before reading); a request over any of them answers `413`. An app that takes more raises them. Temp
files are created `0600`, with a random name in which the client's file name only appears reduced to `[A-Za-z0-9._-]`, and
`Endpoint` deletes them in its `ensure`, when the request is done: **an endpoint that handed `temp_path` to a background job
or kept it for later must copy the file first.** A second file under one field name now deletes the first's temp file.

## 0.7.3

**`CORS#origins` returns a copy, and preflight responses vary by what they ask for.** `cors.origins << "https://b.test"` edited the
live list on 0.6; the reader now returns a copy, so that does nothing (and `<< "*"` can no longer sneak the wildcard past the
credentials check). Assign the whole list with `cors.origins = [...]`. A preflight response now carries
`Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers`. **`Throttle`**: a request that a whitelisted or
blacklisted trusted proxy forwards with an `X-Forwarded-For` that names no client is no longer matched against the lists (it
used to inherit the proxy's whitelist entry and was never throttled); block and release lines are rate-limited in the log like
the refusals. **`CSRF`**: `CSRF_MAX_FORM_SIZE` and `CSRF.new(max_form_size:)` set the urlencoded read limit.

## 0.7.2

**`OPTIONS` answers with `Allow` instead of running the `GET` endpoint.** `get` registered an `OPTIONS` route to its own
endpoint, so an `OPTIONS` request ran the `GET` action and got its body. `get` now registers `GET` and `HEAD` only, and
the router answers an `OPTIONS` itself: `204` with `Allow` listing the methods the path routes (`GET, HEAD, POST,
OPTIONS`), or `404` for a path that routes none. An `options` route you declare still runs, and declaring one on the
path of a `get` no longer raises `DuplicateRoute`. CORS preflights are unchanged: `Handler::CORS` answers them first. In tests,
`client.options(SomeGetEndpoint)` (`Azu::Testing::Client`) now raises `ArgumentError` ("is not routed for OPTIONS")
unless the endpoint declares `options`; call `client.options("/path")` to get the `Allow` answer.

## 0.7.1

No breaking change. It added `Azu::Templates.compile` (#254), which 0.8.1 removed again.

## 0.7.0

**`CSRF` walks a multipart body in one pass, and reads at most 1 MB of a form.** The search for `_csrf` in a multipart body
cost more than the body's size for a body of thousands of tiny parts (seconds of CPU for a request with any cookie); it now
looks at each byte a bounded number of times, gives up after 64 parts, and a `csrf_token` cookie that is not a token the
`SignedDoubleSubmit` handler signed is refused before any body is read (the other strategies cannot check a cookie the
client chose, and read the body first). A urlencoded body is read up to the new `max_form_size` (1 MB by default,
`CSRF_MAX_FORM_SIZE`) and a larger one answers `413`: **a urlencoded form between 1 MB and `upload.max_file_size` that
passed before is now refused** (the 1 MB default shipped in 0.7.0 without a minor-release marker); raise `max_form_size` for such forms. **A browser sends an empty file input as a part with
`filename=""`: it counts as a file part, so `_csrf` must come before it.** Put `csrf_field()` at the top of every form,
above its file inputs (the scaffolds' upload forms too), or send the `X-CSRF-TOKEN` header. A form with more than 64
fields before `_csrf`, or with `_csrf` after the first 64 KB, is refused with `403` where the 0.6.1 behaviour was already
to refuse it after a file. The multipart total size is not bounded by `CSRF`; see the built-in handler reference.

**`Throttle` keeps clients that a proxy forwarded garbage for apart, and its lists take CIDR blocks and refuse bad entries.**
`blacklist` and `whitelist` now accept CIDR blocks (`"10.0.0.0/8"`) and raise `ArgumentError` when the handler is built for
an entry that is not an IP address or block (`"unknown"`, a host name, `"1.2.3.4:80"`); before they compared text and ignored
such entries silently. `trusted_proxies` refuses a catch-all block (`0.0.0.0/0`, `::/0`). Requests from a trusted proxy whose
`X-Forwarded-For` names no client are counted in a bucket of their own, no longer under the proxy's address, so they cannot get
the proxy's own requests refused. The table is kept in two parts (clients in their window, blocked clients), which makes
making room O(1); a table at `max_clients` full of blocked clients cost milliseconds per new client before. Because the
`ipv6_prefix` default of 64 changes how every IPv6 client is counted (see the entry below), this release is a minor one.

## 0.6.2

**`HEAD` responses carry no body.** A `HEAD` to a `get` route sent the `GET` body, which a client reusing the
connection read as the start of its next response. The body is now counted and discarded: the response has the `GET`
status and headers, and a `Content-Length` for the body it would send, even where the `GET` is chunked (a large body,
or compressed by `Handler::Compression`, which a `HEAD` now goes through too). A `Stream` or `EventStream` answers
`HEAD` with `Transfer-Encoding: chunked`, as its `GET` does, instead of `Content-Length: 0`. An exception that no
handler rescues still gets the standard library's plain-text `500` body; the connection is closed after it.

**`CSRF.validate_origin` matches a `Referer` without a port.** It appended a `:` to the expected origin for a `Referer`
with no port, so `http://example.com/form` never matched; an `Origin` with an explicit default port
(`https://example.com:443`) did not match either, and a request without `Host` raised `KeyError`. Origins now compare
by scheme, host (ignoring case) and port (default ports match written or not), a request without `Host` gets `false`,
and the expected scheme is `https` when the app serves TLS and no `X-Forwarded-Proto` says otherwise.

**`Benchmark.load_test` compiles.** Calling it failed to compile, as `Channel` named `Azu::Channel`. It now sends every
request (the remainder of `requests / concurrent` was dropped), `total_requests` counts successes and failures, and
the average is `0.0` instead of `NaN` when nothing succeeds.

**`Azu::AsyncLogging.shutdown` waits for the queue to drain, and runs at exit.** `shutdown` only closed the queues, so
entries still waiting in a batch worker were dropped. A program that exited without stopping the pipeline lost them
too, and could die with an unhandled `Channel::ClosedError` once `Log`'s own `at_exit` had closed its dispatcher. Now
`shutdown` returns once every queued entry and reported error is written. `Azu.shutdown` calls it last, and so does an
`at_exit` registered when the pipeline first starts. Entries sent after it are written synchronously, without the
"Log queue closed" line, and `AsyncLogging.initialize` (or the next `App#start`) starts the pipeline again. Reported
errors are processed one after another in the reporter fiber, not in a fiber each.

**The `current_page?` filter alias is gone.** Crinja names cannot contain `?`, so the alias could never be called from a
template. Use `is_current_page`.

**Date-time strings keep their time.** `date_format`, `time_ago`, `relative_time`, `time_tag`, `l` and
`distance_of_time_between` read `"2024-01-01T10:00:00"` as midnight. They now read it as 10:00 UTC; RFC 3339 strings
keep their offset, and `YYYY-MM-DD HH:MM:SS` is accepted. Output that relied on the midnight reading changes.

**`cycle` alternates inside `for` loops.** It returned its first value on every pass. It now follows `loop.index0`, and
several cycles in one loop are independent. Outside a loop, each list of values keeps its own position.

**`preload_tag` uses the `crossorigin` value you pass.** `crossorigin="use-credentials"` now renders as given instead of
`"anonymous"`. `true` still gives `"anonymous"`, and `false` now leaves the attribute out, even for fonts.

**`Throttle` can read the client behind a proxy, sweeps its table and counts IPv6 by /64.** New options: `trusted_proxies`
(addresses and CIDR blocks; empty by default, which keeps the connection's address as the client), `ipv6_prefix` (64) and
`max_clients` (100 000). What changes without setting any: (1) IPv6 clients are counted by their /64, so several addresses
of one network now share a counter (and a block); (2) trackers whose window ended are dropped by a sweep, and a table over
`max_clients` drops the oldest unblocked clients, where it grew without bound; (3) `blacklist` / `whitelist` entries and
clients are compared in a normalized spelling, so `::ffff:1.2.3.4` and `1.2.3.4` are one address and `2001:DB8::1` equals
`2001:db8:0:0:0:0:0:1`; (4) log lines name the IPv6 network (`2001:db8:0:0:0:0:0:0/64`) instead of the address. An app behind
a proxy that wants one counter per client lists the proxy in `trusted_proxies`.

## 0.6.1

**`CSRF` bounds the body it reads for the form token.** A POST, PUT, PATCH or DELETE without an `X-CSRF-TOKEN` header had its
whole body read into memory by `CSRF`, whatever its size, before any limit applied. A urlencoded body is now read up to
`upload.max_file_size`, and a larger one (by `Content-Length` or as it streams in) is answered `413` instead of `403`, with
`Connection: close`. A multipart body is searched for `_csrf` only in its first 64 KB, and the field must come before the
first file part: a form that put `_csrf` after an `<input type="file">` (or after more than 64 KB of other fields) is now
refused with `403` where it passed. Move `csrf_field()` to the top of the form, or send the token in the `X-CSRF-TOKEN`
header. The `_csrf` field of a file's content is no longer taken for the token, and the urlencoded content type is matched
whatever its case.

## 0.6.0

**`CORS` refuses a wildcard with credentials, and sends `*` for a plain wildcard.** `CORS.new(origins: ["*"], credentials: true)`
(and setting either option so that both hold) now raises `ArgumentError` where it used to echo every `Origin`, `null` included,
with `Access-Control-Allow-Credentials: true`: any site could read a signed-in user's responses. List the origins (or a regex)
when you need credentials. With `origins: ["*"]` and no credentials the response now carries the literal
`Access-Control-Allow-Origin: *` instead of the echoed origin (it still varies by `Origin`). `Origin: null` is matched only when
`"null"` is listed (it matched `"*"` and any permissive regex), an `Origin` that is not a plain `scheme://host[:port]` or comes
in several headers is refused with `403`, and a preflight must ask for allowed headers only: before, one allowed header in
`Access-Control-Request-Headers` let the others through, while a preflight with no `Access-Control-Request-Headers` at all (it was
refused with `403`) now passes for an allowed origin and method and gets no `Access-Control-Allow-Headers`. An app that built `CORS` with the wildcard and credentials must change
its configuration to boot, which is why this release is a minor one.

## 0.5.134

**Responses get the request variables, and CSRF values need a CSRF handler.** A response's `view` had no request: its
template got no `csrf_token`, `current_path` or other [request variable](templates/helpers.md#request-variables), and
reading `flash.notice` raised a `500`. `view` now takes the request from `Azu::RequestContext` while a request is served,
so `view_with_context` is only needed for a request you hold yourself. `csrf_token`, `csrf_tag` and `csrf_metatag` are now
there only once the app has built an `Azu::Handler::CSRF` (`Handler::CSRF.in_use?`), and only then does a render issue the
token and set its cookie. Before, every render with a request did, and in production without `CSRF_SECRET` it raised a `500`.
An app that prints CSRF values without the CSRF handler gets empty fields: mount the handler. The generated `form_for_*`
and `button_to_delete_*` helpers now include the `_csrf` field, so a `csrf_field()` inside them can go (a second field with
the same token is harmless).

**`current_path` and `current_url` are variables, not functions.** The template functions of these names hid the request
variables, so `{{ current_path }}` printed the function instead of the path. They are gone: write `{{ current_path }}`
and `{{ current_url }}`. `{{ current_path() }}` now fails with "not callable". `back_url()` reads the `referer` variable
(it read `http_referer`, which nothing set, so it always answered its fallback) and answers the fallback for an
unsafe URL such as `javascript:`. `config.i18n.available_locales` (`I18N_AVAILABLE_LOCALES`) is now applied to
`Helpers::I18n`, so `Handler::Locale` can pick those locales.

**Spark checks its secret at boot.** In production and staging `Azu::Spark.install` raises
`Azu::Spark::ConfigurationError` when no secret is configured (`SPARK_SECRET` or `Azu::Spark.configure { |c| c.secret = ... }`),
before it registers a route. Before, the app started and every page that called `Azu::Spark.render` answered `500`. Set the
secret before calling `install`.

**An unreadable body is a 400 or 413 without `Rescuer` (fix).** An endpoint read its body outside its own error handling, so
a multipart body it could not parse, or one over `upload.max_file_size`, answered `500` when no `Rescuer` was in the
chain. The endpoint now answers `400` and `413` itself, like a contract violation. A malformed `Content-Type` header (for
example `application/json; charset`) is a `400` instead of a `500`, with or without `Rescuer`.

**`i18n.missing_key_format` is used (fix).** A missing translation always printed `[missing: key]`; the format set in
`config.i18n.missing_key_format`, `I18N_MISSING_KEY_FORMAT` or `Helpers::I18n.missing_key_format=` was stored and never
read. It now formats the marker, `%{key}` replaced by the key. The default is the same text as before.

## 0.5.133

**`csrf_tag` and `csrf_metatag` carry the token of `csrf_token` and of the cookie (a fix).** `view` issued a new token for
each of the three variables and each one replaced the CSRF cookie, so only `csrf_metatag` matched it: a form that printed
`{{ csrf_token }}` or `{{ csrf_tag }}` was refused with 403 under the default `SignedDoubleSubmit` strategy. Now a render
issues one token, the cookie holds it, and a second `view` in the same request (a layout and a partial) reuses it. The cookie
is still set on every `view` with a request, whether or not the template prints a token. The same held for an endpoint's
`csrf_token`, `csrf_tag` and `csrf_metatag` helpers and for any code calling `Handler::CSRF.token(context)` twice under
`SignedDoubleSubmit`, `DoubleSubmit`, or the synchronizer token with the cookie store on a request without the cookie: each
call issued a token and replaced the cookie. Now one response gets one token, the one its cookie holds; a deleted, expired
or other-path cookie of that name is replaced, not reused.

**Request variables are computed when a template reads them.** `current_path`, `flash`, `csrf_token` and the other
variables `view` gives a template with a request cost nothing when the template does not print them. `{{ debug() }}` lists
only the ones the template has read so far, and `Azu.session_adapter`'s `flash` reader runs only for a template that reads
`flash`.

**Template macros and context-free includes keep no state between renders (security).** A macro was kept on the template,
which every request shares, with the defaults it evaluated: `{% from "m.jinja" import panel %}` could import the macro an
earlier request defined, its values included. `{% include "x.jinja" without context %}` rendered in the environment's
global context, so its `{% set %}` reached every later render. Both now belong to their own render: an imported file's
macros and top-level variables still reach the importing page (an imported macro can call its file's other macros), and
an `import` of a plain text template (`m.txt`) no longer turns escaping off for the rest of the page. As in 0.5.120, those
copied names replace the page's own of the same name (view data, macros defined before the import), so a macro library
needs names no page uses: see [Import macros](templates/engine.md#import-macros).

**A template a helper renders starts from the global context.** `templates.render(...)`, or `view` without a request,
called inside another render (a helper that renders a fragment) sees only the globals and the data it is given: not the
outer page's view data, `csrf_token` or `current_path`. Before, it inherited them, and a fragment cached with
`Azu.cache.fetch(key) { ... }` could hold one user's values for everyone. Pass what the fragment needs explicitly.

## 0.5.131

**The router finds routes in its own segment tree; the `radix` shard and `Router#radix` are gone.** Routes declared
as before keep matching as before, with these differences:

- Nested routes of one method work: `get "/posts/:id"` with `get "/posts/:post_id/comments"` used to leave both
  unreachable (or raise `Radix::Tree::SharedKeyError`); each now matches with its own parameter names.
- A `:` or `*` inside a segment is literal: `/users:search` matches only that path, where radix read a parameter
  `search` there.
- A route's parameters are only its own: radix also returned the parameters of a branch it had tried and left (a
  glob route got the `id` of a `/files/:id/meta` route).
- Two routes of one method whose paths differ only by a trailing slash or by their parameter names (`/a/:id` and
  `/a/:name`) raise `Azu::Router::DuplicateRoute`, where radix accepted both and found the second never (or neither).
  A wildcard that is not the last segment raises `ArgumentError`.
- A route path that does not start with `/` raises `ArgumentError` when it is declared. Radix accepted it and matched
  nothing, so a typo such as `get "files/private/*rest", Deny` next to `get "/files/*path", Download` silently let
  the broader route serve the private files.
- `App#start` freezes the router (and the routers of mounted apps) before it listens: adding a route afterwards
  (`router.get`, `add`, `root`, `ws`, `mount`, `register`) raises `Azu::Router::Frozen`. Declare every route, and call
  `Azu::Spark.install`, before `start`.
- `Router#radix` is removed. Code that looked routes up with `router.radix.find("/get/users")` should call
  `router.process(context)`, or read `router.registered_routes`; `route_info`, `registered_routes` and `Route#resource`
  are unchanged.

**The router has no path cache.** `Router#path_cache` and its `stats` are gone, and `clear_path_cache` does nothing: the
router finds routes in a tree of path segments that reads the request path in place (a static route allocates nothing),
so there is nothing left to cache. Remove calls to `path_cache`; calls to `clear_path_cache` can stay.

## 0.5.130

**The test client's cookies follow the browser's paths (`azu/testing`).** `Azu::Testing::CookieJar` sent a cookie set
without `Path` to every path, where a browser keeps it for the directory of the request that set it (RFC 6265 default
path), which is how the CSRF bug above passed the client. Now a cookie set without `Path` on `GET /auth/login` goes to
`/auth/...` only; a name is held once per path (an expired `Set-Cookie` removes that name and path, `delete(name)`
every path of it); a request carries longer paths first; and `client.cookies["name"]` / `to_h` give the shortest
path's value. `CookieJar#absorb` takes the request path as a second argument (default `/`). A spec that now misses a
cookie had a page that sets it without `Path` in a subdirectory: the app should set `Path` (a browser would not have
sent it either).

## 0.5.129

**The CSRF cookie is sent to every path (fix).** `Handler::CSRF` set its token cookie without a `Path`, so browsers kept it
for the directory of the page that issued it (the RFC 6265 default path): a token issued on `GET /auth/login` was stored for
`/auth`, was not sent with `POST /session`, and that form was refused with `403 CSRF token validation failed` under
`SignedDoubleSubmit`, `DoubleSubmit` and `SynchronizerToken` with the default `CookieTokenStore`. A form that posts into its
own directory (`/posts/new` to `POST /posts`) worked, which hid it. The cookie now carries `Path=/`. Nothing needs to be done.
Until the old cookies expire (`cookie_max_age`, 24 hours by default) a browser can hold an old directory cookie next to the
new one, and it sends both to paths inside that directory, the longer path first (RFC 6265 section 5.4).
`HTTP::Cookies.from_client_headers` keeps the last cookie of a name, so the handler compares against the new `Path=/`
cookie, the one the page's token was issued with. `SignedDoubleSubmit` and `DoubleSubmit` set a new cookie with every
token, so their forms work from the first page rendered after the upgrade. `SynchronizerToken` with `CookieTokenStore`
reuses the token a request already carries and sets no cookie, so a browser that holds only an old `/auth` cookie keeps that
token, and is refused on `POST /session` as before, until the cookie expires or a page outside `/auth` issues a new token.
`SessionTokenStore` sets no cookie and is not affected. To drop the old cookies at once, give the handler a new
`cookie_name:`; forms rendered before the deploy are then refused once.

## 0.5.128

**An invalid `SecurityHeaders` value raises `ArgumentError` when the handler is built.** A value a header cannot carry (a
line break in `content_security_policy:`, `frame_options:` or `referrer_policy:`) used to raise on every request, which
`Rescuer` answered with a `500`; the application now fails to boot instead.

## 0.5.122

**The router matches only exact HTTP methods and paths that start with `/` (security fix: upgrade).** A request whose
method is not one of the verbs spelled exactly (`GET`, `POST`, ...: methods are case-sensitive, so `get` is not `GET`) or
whose path does not start with `/` answers `404`, and a WebSocket route is reached only by a `GET` upgrade. The route a
request reaches is now always the one its `request.method` and `request.path` name, which handlers before the router rely
on. Clients that send the standard verbs in upper case see no change; a client that sends one in lower case
(`fetch(url, {method: "patch"})` sends `patch`, as does `curl -X patch`) must send `PATCH`.

## 0.5.121

**Generated apps still print `csrf_metatag` escaped until azu_cli changes (urgent).** The template variables `csrf_tag` and
`csrf_metatag` that azu fills in from the request are `Crinja::SafeString` now, but this alone does **not** fix generated
apps: their pages pass `csrf_tag` / `csrf_metatag` as Strings in `view data: {...}`, and `view` only fills the context
variables a page has not set itself, so the page's String wins and `{{ csrf_metatag }}` prints `&lt;meta ...`. Since 0.5.120
(autoescape) such a page carries no CSRF token in that tag. Until azu_cli is updated, either write `{{ csrf_metatag | safe }}`
in the template or stop passing the String and use the variable azu provides. A page that already says `| safe` (the generated
scaffold and auth pages do) works with both.

**`urlize` is Azu's own.** It escapes the text around the links and links only `http`, `https` and `www.` addresses
(Crinja's linked any `scheme://`, `javascript://` too, and did not escape the rest of the text). `button_to` and
`button_to_delete_*` write the `confirm:` text as `\uXXXX` escapes inside the JavaScript string, so an apostrophe no
longer ends it. `truncate_html` returns a `SafeString` for a safe input; `simple_format` and `auto_link` validate the
tag and attribute names like `content_tag`.

## 0.5.120

**`.jinja` and `.j2` templates are autoescaped (security).** Crinja escapes only `html`, `htm` and `xml` templates, and
`.jinja` is the framework's own default extension (`Renderable#page_path`), so `{{ user.name }}` in a page was stored XSS
unless the author remembered `| e`. Now every template is escaped, string templates included, except formats that are not
HTML: a name with the inner extension `txt`, `text`, `json`, `js`, `mjs`, `css`, `csv`, `md`, `markdown`, `yml`, `yaml`,
`sql` or `sh` (`mail.txt.jinja`, `data.json.jinja`) is not escaped (JSON and JavaScript need their own encoding,
`{{ value | tojson }}`); `xml`, `rss`, `atom`, `svg`, `html` and `htm` stay escaped. Migration:

- No change is needed for `| e`: `{{ value | e }}` returns an already-escaped value that is not escaped again, so existing templates
  keep their bytes. Do not chain a filter after `| e` (`{{ x | e | upper }}`): `upper` returns plain text, which is then
  escaped once more; escape last, or drop the `| e`.
- A value that is markup on purpose (HTML you built or sanitized) needs `{{ value | safe }}`. Before, it printed raw by
  accident. Values passed through `t()` that contain HTML are escaped now; render them with `| safe`.
- The built-in helpers return `Crinja::SafeString` and are not escaped. Your own `Azu::Helpers.function`/`filter` that
  return HTML must return `Crinja::SafeString.new(html)`, built from escaped parts.
- Filters that build a new string drop the safe mark, so their result is escaped (again): `upper`, `lower`, `title`,
  `capitalize`, `truncate`, `replace`, `format` and the `~` operator (`{{ (x | safe) ~ "a" }}`, `{{ (x | e) | upper }}`
  gives `&amp;LT;`). Apply them to the plain value and mark the result last (`{{ (x | upper) | e }}`), or build the markup
  yourself with `Crinja::SafeString.new(html)` in a helper. `trim`, `default`, `join` and `{% set %}` keep it.
- Strings your code passes into a template that are HTML must be marked: `{{ csrf_tag }}` and `{{ csrf_metatag }}` are
  safe when azu supplies them (not when your page passes its own String under that name), but `Azu::Spark.render(...)` and `Azu::Spark.script_tag` return plain Strings, so a
  template that prints them needs `{{ spark_view | safe }}`. Wrap them as `Crinja::Value.new(Crinja::SafeString.new(html))`
  in the data you pass to `view`.
- Escaping is decided per template name, also for `{% include %}`, `{% extends %}` and imports: a `.html` or `.jinja`
  page that includes `x.js.jinja` or `x.md.jinja` prints that part unescaped, and a `.txt.jinja` that includes a
  `.jinja` prints that part escaped. Name partials for what they contain.
- `urlize` expects escaped plain text; markup in a `SafeString` is tolerated (tags, attributes and existing links are left
  alone), but it is no sanitizer. `html_attrs` of `simple_format` and `link_attrs` of `auto_link` escape their values and
  check names, but do not check URLs: do not put a user value in `href`/`src` there.
- `{% autoescape false %}...{% endautoescape %}` turns the escaping off for a block, `{% autoescape true %}` on again
  inside a plain text template.
- The global `Crinja.render("{{ x }}", ...)` (Crinja's own default environment, not `Azu::CONFIG.templates.crinja`) does
  not escape. Use the Azu environment for anything that prints user values.
- Last resort: `Azu::CONFIG.template_autoescape = false` or `TEMPLATE_AUTOESCAPE=false` restores the old behavior (the start logs a warning while it is off, and when the variable holds a
  value other than `true` or `false`, which leaves escaping on).

**Template helpers escape what they used to pass through (security).** `highlight` and `content_tag` escape their text and
content (pass markup as a `SafeString`: another helper's output or `| safe`); `link_to`, `button_to` and `form_tag` replace a
URL whose scheme is not `http`, `https`, `mailto` or `tel` (`javascript:`, `data:`, `vbscript:`, ...) with `#` or
`about:invalid`; an attribute name that is not `[A-Za-z_:][-A-Za-z0-9_:.]*` is dropped and a tag name that is not a name
raises `ArgumentError`. Check `content_tag(content="<b>x</b>")` and links to other schemes (`sms:`, `ftp:`, custom app schemes):
write those `<a>` tags yourself. See [attribute names and URLs](templates/helpers.md#attribute-names-and-urls).

## 0.5.119

**A contract identical to a bare `include Azu::Request` is not parsed or checked for a request without a `Content-Type`.**
Only a contract with no fields, no `validate`/`use` rules and no methods of its own skips it; its params are read on
first use, as for the bare `Azu::Request`. A request with a `Content-Type` is parsed and checked as before, and so is
every request to a contract with fields, with rules (its own or inherited) or with any method of its own: its own
`errors`, a constructor such as `from_www_form` or `initialize`, or any other.

**`HTTP::Request#path_params=` takes a `Hash(String, String)`** (it was untyped), and `path_params` is allocated on first
read. `Router#process` returns `""` for a routed request instead of the rendering of the context.

## 0.5.117

**`Static` refuses files of an unknown type.** A file whose extension has no content type used to raise `KeyError: Missing MIME type`
and answer `500` (`.jinja`, `.ico`, `.webmanifest`, `.md`, `.mp4`, an extensionless file, and in a minimal container more).
It is now refused as if there were no such file: the request goes to the next handler (the router answers its 404), or answers
`404` with `fallthrough: false`. There is deliberately no default type, so a template is never sent as a download. Azu now
serves `.ico .webmanifest .avif .mp4 .webm .mp3 .ogg .wav .m4a .csv .vtt .mjs .eot .rss .atom` and an extensionless file
`/.well-known/<file>` and `/.well-known/<dir>/<file>` (as `text/plain`), plus archives (`.zip .gz .tgz .tar .bz2 .xz .7z`),
`.ics .jsonld .xhtml .bmp .tif .tiff`. The table of types belongs to `Static` and is the same on every host: the operating
system's `/etc/mime.types` is no longer consulted (a host that had it served `.yml` or `.md`; none does now). If you serve a type
that is not in it, add it with `Static.new(mime_types: {".heic" => "image/heic"})`. Azu no longer registers `.woff`, `.ttf` and
the others in the process-wide `MIME` registry; code that called `MIME.from_filename` for them must register them itself. Check any route that shares a path with a file of an unknown type: the
router now answers it. See [Handler::Static](handlers/built-in.md#which-files-are-served).

## 0.5.116

**`Static` can refuse paths (additive, nothing to change).** `Azu::Handler::Static.new(except: ["/templates"])` never serves
`/templates` or anything below it; the request goes to the next handler, or answers `404` with `fallthrough: false`. Without
`except` the handler behaves as before. Use it when template sources live under `public/`:

```crystal
Azu::Handler::Static.new("public", except: ["/templates"])
```

`except` is the supported way to keep paths under `public/` from being served. See [Handler::Static](handlers/built-in.md#handlerstatic).

## 0.5.115

**`Vary` fields are compared as whole tokens.** `CORS`, `Static` and `Negotiation` add their fields through one helper that splits every `Vary` line on commas and compares
trimmed tokens case-insensitively, so `Vary: Accept-Encoding` no longer hides `Accept` and `X-Origin` no longer hides `Origin`. A `Vary: *` is left untouched (`Negotiation`
used to extend it). The fields are written as one comma list. `Compression` sets no `Vary: Accept-Encoding` itself (out of scope here). A subclass of `Throttle::Refusal` is
treated like any error you raise: it shares neither the page cache nor the fingerprint of Throttle's own refusal.

## 0.5.114

**Throttle's HTML 429 page is cached for a second.** The page of `Throttle`'s own refusal (not an error you raise: a `RateLimitError` of yours, or a subclass,
always renders its own text) is rendered once a second per templates, `Retry-After` and locale, and the response carries the `error_id` the page shows, so refusals within
that second share an id. A custom `error.html` must therefore not depend on the request; development renders the page every time. Nothing reports a Throttle
refusal to `ERROR_REPORTER`, which would want an id per occurrence.

**`QueryStore#playground_available?` takes a `Configuration`.** It was `playground_available?(config : DatabaseConfiguration = Azu::CONFIG.database)` and judged the
environment by the global configuration; it is now `playground_available?(config : Configuration = Azu.current_config)` and reads the database switch and the
environment from the configuration of the app serving the request. A caller that passed `config.database` passes `config`. The dashboard's N+1 and slow-query thresholds
follow the serving app the same way, and the `<resource>_path` template filter of an endpoint is registered with `Helpers::Registry` (every app's templates have it).
`CORS` adds `Origin` to a `Vary` the response already has (it replaced it), and sets `Vary: Origin` on a request without an `Origin` header, in every configuration. With
`origins: ["*"]` the request's `Origin` is reflected in `Access-Control-Allow-Origin`, so that response now carries `Vary: Origin` too (it sent no `Vary` before): a visible cache
behaviour change, and a shared cache keeps one entry per origin.

## 0.5.113

**Templates are compiled outside development.** With `template_hot_reload` off (the default for `staging`,
`production` and any environment other than `development`, `test` and `pipeline`), `Azu.prepare` reads and parses
every template once and requests no longer read template files: an edit to a template file needs a restart, where
before it showed on the next request, and a template with a syntax error now stops the boot (with its name and
line) instead of failing its first request, including a file that is not a template (a vendored `index.html`; list
those in `template_compile_ignore`). Set `template_hot_reload = true` (or `TEMPLATE_HOT_RELOAD=true`) to keep
reloading in an environment. See [Configuration](configuration/options.md#templates).

## 0.5.112

**Every JSON error is a RFC 7807 problem document.** The router's `404` and every other
`Response::Error` (`BadRequest`, `AuthenticationError`, `Forbidden`, `RateLimitError`, a `500` from an unhandled
exception, ...) predated problem+json and answered JSON clients with a PascalCase body. They now use the shape the contract
`422` already had:

```json
{"type": "about:blank", "title": "Not Found", "status": 404,
 "detail": "The server can't find the requested resource.", "errors": [], "error_id": "4f2a...", "instance": "/missing"}
```

- Before: `{"Status": "not_found", "Link": ..., "Title": "Not Found", "Detail": ..., "Source": "/missing", "Errors": [],
  "ErrorId": ..., "Fingerprint": ..., "Context": null, "Backtrace": null, "Timestamp": ...}` with `Content-Type: application/json`.
- `Status` (a string) becomes `status` (an integer); `ErrorId` becomes `error_id`. `Source`, `Link`, `Fingerprint` and
  `Timestamp` are gone from the body (`X-Error-ID` and `X-Error-Fingerprint` stay headers). `instance` is the request path
  and nothing else: an error's own `source` text is never sent. `Context` and `Backtrace` become `context` and `backtrace`,
  present in development only.
- **Content-Type.** The body is the same for every JSON client, but `Content-Type: application/problem+json` is sent only to a
  client whose `Accept` header names `problem+json`; `application/json` and other `+json` types get the same body as
  `application/json`. (This includes the contract `422` and the `406`.) The OpenAPI document lists both media types.
- `title` is the error's own title (`Insufficient Funds`), not always the status phrase RFC 7807 suggests for `about:blank`; read
  `status` for the class of error and `detail` for the explanation.
- Handlers that wrote their own refusals now write a negotiated `Response::Error`, so a JSON client gets the same document
  and others get the text/HTML/XML body: `CSRF` (403), `Throttle` (429, `Retry-After` kept), `Static` (400 invalid path, 405,
  `Allow` kept), `CORS` (403, any `Access-Control-*` header already set is removed) and `IpSpoofing` (403). Bodies that were
  empty or a fixed sentence are now the error document.
- Still not problem+json, by design: the Spark protocol frames (`azu/spark`), the WebSocket upgrader's refusals, the
  development dashboard's own JSON (`{path}/sql`), and `Handler::HealthCheck`'s `{"status": ...}`.
- `Response::Error#xml` escapes the title, detail, source, messages and request context (they went into the XML
  unescaped).
- Migration: accept the `+json` suffix and read the new members, or set `config.error_format = Azu::ErrorFormat::Legacy`
  (keeps all old bodies, as `application/json`, for one more minor release). The OpenAPI document follows the setting
  (`Azu.Error` is the problem schema, `Azu.LegacyError` the old one). `Testing::Response#problem?` is true for the
  `application/problem+json` content type and for a JSON body with the `type`, `title` and `status` of a problem document, so it
  holds whichever `Accept` the test client sent.

## 0.5.111

**`Router#path_cache` is internal.** It is `:nodoc:` and its `get`/`set` now take the method and the path
(`get("GET", "/x")`) instead of one `"GET:/x"` key; `path_cache.stats` and `clear_path_cache` are unchanged. Nothing
outside the router should call `get` or `set`.

**`include Azu` is a supported facade, and `Azu::App` can start itself.** `include Azu`, `configure` and `Azu::CONFIG`
are the single-app facade (global configuration, one app per process); they are not deprecated and log no warning.
`Azu.warn_global_shim` and `Azu.reset_shim_warning` are gone (nothing calls them). `Azu::App#start` serves an app built as
a value with the lifecycle the facade used (prepare, bind, SIGINT/SIGTERM, drain, `Azu.shutdown`), and `MyApp.start` is now
`Azu::App.default.start`, one code path. New: `App#start(handlers, signals:, teardown:)`, `#running?`, `#address`,
`#prepare`, `App::AlreadyRunning`. An app starts **once**: `start` on a running app raises `AlreadyRunning`, on one that has stopped (or begun to shut down)
`AlreadyStopped`; build a new `Azu::App` to serve again (a `start` that failed to bind can be repeated, the same handlers
included). Differences for facade users: `start` on a stopped `App.default` raises; a SIGINT/SIGTERM now stops every app started with `start`; `Azu.shutdown` runs when the last of them stops.
Reference: [App](api/app.md).

**`Handler::DevDashboard` serves in development only.** It used to serve in whatever environment it was added to the handler
list in (the generated apps guard it with `if Azu::CONFIG.env.development?`, but an unguarded `DevDashboard.new` exposed
request data, SQL and configuration in production). It now checks `Azu.current_config.env.development?` on every request
and otherwise calls the next handler, so `/dev-dashboard` (and `{path}/sql`) answer whatever the app routes there, a `404`
when nothing; building one outside development logs one `WARN`. The SQL playground's CSRF exemption is registered whatever the
environment (it only matters while the dashboard serves). There is no `allow_in_production` option. `Handler::PerformanceMonitor` has no
HTTP endpoint and is unchanged. Migration: an app that relied on the dashboard in `staging` or `test` runs it in
development (`CRYSTAL_ENV=development`); specs that call the handler set the environment (`with_azu_env(Azu::Environment::Development)`).

**The default bind host is `127.0.0.1` in development.** `Azu::Configuration#host` used to default to `0.0.0.0` in every
environment, and an unset `CRYSTAL_ENV` means development, so a forgotten variable exposed the development pages on every
interface. Unset still means development; the default host now depends on it:

- Development, with neither `HOST` nor `config.host=` set: `127.0.0.1` (was `0.0.0.0`).
- Every other environment: `0.0.0.0`, as before. An explicit `HOST` or `config.host` is always kept.
- `start` logs one INFO line when the environment came from the default:
  `CRYSTAL_ENV not set, running in development, listening on 127.0.0.1`.
- Migration: an app run in development that must be reached from another machine, a container or a VM port-forward sets
  `HOST=0.0.0.0` (or `config.host = "0.0.0.0"`). Deployments that set `CRYSTAL_ENV` (production, staging, ...) are unchanged.
- `Configuration#host` is no longer a plain `property`: `host=` accepts `nil` or `""` to go back to the default.
- `start` logs a WARN when the server listens on a loopback address inside a container (`/.dockerenv` or Podman's `/run/.containerenv` exists, or
  `KUBERNETES_SERVICE_HOST` is set), naming the fix `HOST=0.0.0.0` (the usual cause: development, the default, a container);
  and a WARN when `CRYSTAL_ENV` was never set and the host is not loopback (the development pages are served on every
  interface). `Configuration#container=` overrides the detection.
- Test, Pipeline, Build, Integration and Acceptance are not development: they keep binding `0.0.0.0` unless told otherwise.

## 0.5.110

**`Handler::Static.new` falls through by default.** `fallthrough` defaulted to `false`, so a `Static` placed before the
router answered `404` for every path that is not a file and `405` for every `POST`, hiding all the routes; only the default
stack (`fallthrough: true`) worked. The default is now `true`: a request that is not a `GET`/`HEAD` for an existing file goes to the next
handler. Code that relied on the old default as the last handler of a chain (to answer 404/405 itself) must pass
`fallthrough: false`; passing `fallthrough: true` explicitly, as the docs and the default stack do, changes nothing.

## 0.5.109

**`Handler::Static` redirects to the right path.** The redirect for a directory requested without its trailing slash answered
`Location: /subdir//` (two slashes), and one for a path that was not in its normal form (`/a/../b.txt`) answered `/b.txt/` (a slash added to a
file). Now `/subdir` redirects to `/subdir/`, `/a/../b.txt` to `/b.txt`, and the query string is kept. A
path-only `Location` starts with exactly one `/`, so `//evil.com` is redirected to `/evil.com`, never to a protocol-relative URL.

**CSRF has a production guard.** `Handler::CSRF.new` without `secret_key:` generated a random key for each instance, silently, so after a restart
or on a second server every token it had issued was rejected. It now uses `Azu::Env.secret("CSRF_SECRET")`: the `CSRF_SECRET` variable when set, a
random per-process key outside production with one warning in the log, and `Azu::Env::MissingError` ("CSRF_SECRET is not set") when the environment
is in `Azu::Env.strict_environments` (production by default) and neither a key nor the variable is set. An explicit `secret_key:` / `secret_key=`
wins. The key is resolved when the handler is built (`CSRF.default` and `CSRF.configure`: after the block, so the block may assign it), so a
misconfigured production app fails at boot. Instances built without a key in one process now share the one fallback key (they signed with
different keys before). Apps made with `azu new` already set `CSRF_SECRET` and refuse to start without it, so they are unaffected.

**A 4xx is logged below error level and without an exception.** `Router` logged every unmatched route (404) with `Log.error(exception: ...)` under
the root source, and `Handler::Rescuer` logged every raised `Response::Error` (4xx and 5xx) at `warn` with its exception. A client error is not a
server fault, so now: a 404 from the router and a 4xx `Response::Error` caught by `Rescuer` produce one line with the reason
(`GET /signup -> 400 Bad Request: email is invalid`) and no exception or backtrace, at `debug` (the request log has the access line), except `401`
and `413` at `info` and `403` and `429` at `warn`, so the default log level still shows them. The path and detail in the line are cut to 200 characters and
stripped of control characters (`Azu::LogText.safe`, also used by `Handler::Logger` and `SimpleLogger`). The log sources are `Azu::Router` and
`Azu::Rescuer` (the Rescuer's was `http.server`, the Router's was the unnamed root source; bind `Azu::*` instead). The access lines of `Handler::Logger` and `SimpleLogger` keep targets up to 2048 characters, escape C0/C1 controls, line separators and bidi overrides in them (also in the user agent, request id and endpoint), and replace credential-looking query parameters (`?token=...`) in the logged target, so `Log.setup("Azu::*")` selects them. A raised 5xx `Response::Error` moves from `warn` to `error`
(with its exception and backtrace): that includes deliberate `503`/`504`s you raise yourself. An unexpected exception is `error` as before. The
response status and body are unchanged. If you alert on `warn`/`error` lines for 404s, watch the request log (`Handler::Logger`) instead.
The refusals that `CSRF`, `CORS`, `IpSpoofing` and `Throttle` write themselves (they never reach `Rescuer`) are logged the same way, once per refused request, by
`Azu::LogText.log_refusal` under the sources `Azu::Handler::CSRF`, `Azu::Handler::CORS`, `Azu::Handler::IpSpoofing` and the app's own log (`Throttle`): `403` and `429` at `warn`.
Each line also names the client (the address of the connection) and the `Origin` header, cleaned like the path. `CSRF` no longer logs the request headers
(cookies and credentials) at `debug`. `Throttle` writes at most `Throttle::LOG_PER_SECOND` (10) refusal lines a second per handler and begins the next second with one
line saying how many it left out (`suppressed 40 similar refusals in the last second`). The other three log every refusal.

## 0.5.108
**Templates are preloaded outside development.** With `template_hot_reload` off (the default for `staging`,
`production` and any environment other than `development`, `test` and `pipeline`), `Azu.prepare` reads and parses
every template once and requests no longer read template files: an edit to a template file needs a restart, where
before it showed on the next request, and a template with a syntax error now stops the boot (with its name and
line) instead of failing its first request, including a file that is not a template (a vendored `index.html`; list
those in `template_preload_ignore`). Set `template_hot_reload = true` (or `TEMPLATE_HOT_RELOAD=true`) to keep
reloading in an environment. See [Configuration](configuration/options.md#templates). This mode was called "compiled"
in 0.5.113 to 0.5.133; the word is reserved for templates compiled to Crystal code (planned). The old names still work but are
deprecated: `Templates#compiled?`, `Templates#compile_ignore` / `compile_ignore=`, `Templates.new(..., compile_ignore:)`,
`Configuration#template_compile_ignore` / `template_compile_ignore=` and `TEMPLATE_COMPILE_IGNORE` (read when
`TEMPLATE_PRELOAD_IGNORE` is not set); use `preloaded?`, `preload_ignore`, `preload_ignore:`, `template_preload_ignore`
and `TEMPLATE_PRELOAD_IGNORE`.

**Azu's error pages no longer depend on the working directory.** `error.html` and `error_debug.html` are compiled into
the binary (`Azu::Templates::BUILTIN`), and `ERROR_TEMPLATE` defaults to the directory they live in inside the azu source
(resolved at compile time) instead of `./src/azu/templates`. Before, an app that installed azu as a shard found no
error template unless it ran from a checkout of azu, so the production HTML error page raised
`Crinja::TemplateNotFoundError`. The lookup order is now your `templates.path` directories, then `ERROR_TEMPLATE`, then the
built-in pages (before: `ERROR_TEMPLATE` first), so an `error.html` in your own template directory now overrides the
built-in one. `TEMPLATES_PATH` is unchanged: it is for your templates and a relative entry is still resolved against the
working directory, so run the app from its root or set an absolute path.
`Templates#crinja.loader` is a `Crinja::Loader::ChoiceLoader` now, not a `FileSystemLoader`. The built-in pages are autoescaped like the file based ones, an `error.html` of yours that fails to render falls back to the built-in page, and a debug log line names an `error.html` that replaces a built-in one.

**The development error context redacts credentials.** `Azu::ErrorContext` (the request/process data an error carries in development and
puts in the JSON, text and `error_debug.html` pages) used to hold the whole process environment and the raw request headers. The
environment is now `Azu::Env.redacted(ENV.to_h)` (values of names such as `*_SECRET`, `*_TOKEN`, `*_KEY`, `*PASSWORD*`, `*COOKIE*`, `*AUTH*` become
`[FILTERED]`, and the password of a `scheme://user:password@host` URL is hidden), the header values of `Authorization`, `Cookie`, `Set-Cookie`,
`X-CSRF-Token`, `X-API-Key` and the like are `[FILTERED]` in `to_h`/`to_json` (`ErrorContext#headers` is still the real request headers; use
`#redacted_headers` for display), and query parameters with such names are redacted in `#redacted_params`. If you read a secret value out of an
error JSON in development, read it from the environment instead. `Azu::Env.redact` also filters names with `PASS`, `PWD`, `JWT`, `SESSION`, `SID`, `SIGNATURE`, `CONNECTION_STRING`, `OTP`, `PIN`, `CVV`, `CARD`, `SSN` (hyphenated header names count like underscored ones), and the new `Azu::Env.redact_url` hides URL passwords and credential query parameters (`?token=...`) anywhere in a value (referer, endpoint). The development exception page (the `exception_page` shard) is built from redacted query parameters, response headers and response cookies.

## 0.5.107

**`Azu::CQL.schema` runs PostgreSQL on CQL's native engine pool.** With a CQL release that has
`CQL::Postgres::EngineSource`, schemas for `postgres://` and `postgresql://` URLs use CQL's own wire driver and
`AsyncEngine` pool instead of crystal-db's pool with the `pg` shard. SQLite, MySQL and `cockroachdb://` are unchanged
(`cockroachdb://` runs on the engine only with `driver: :engine`, which is experimental: CQL checked it against CockroachDB 24.3 only).
Check these before upgrading:

- **Errors.** Server errors are `CQL::Postgres::Error` subclasses (`UniqueViolation`, `ForeignKeyViolation`,
  `SerializationFailure`, ...), not `PQ::PQError`, and not `DB::Error`. Pool errors are `CQL::Postgres::PoolTimeout` and
  `PoolClosed`. A connection that cannot be opened is still `DB::ConnectionRefused`. Migration: change
  `rescue ex : DB::Error` to `rescue ex : DB::Error | CQL::Postgres::Error` (and `PQ::PQError` to `CQL::Postgres::ServerError`).
- **Failed-query text.** The dashboard shows the SQLSTATE and the message the driver considers safe (`undefined table (SQLSTATE 42P01)`),
  not the relation or column name: the driver keeps server wording that can carry bound values out of messages. CQL could attach
  `table_name`/`column_name` metadata to the error; that is a proposal for CQL, not part of this change.
- **Decoding.** `numeric` columns decode to `CQL::Postgres::Types::DecimalText` and arrays to their text form;
  `read(Float64)` or `read(Array(Int32))` on them raises `TypeCastError`.
- **TLS and URLs.** `sslmode` accepts `disable`, `prefer`, `require` and `verify-full`. `verify-ca`, `allow`, `sslcert` and `sslkey`
  raise `ArgumentError` when the schema is created, even with `lazy: true` (the URL is parsed then). The engine keeps a literal `+`
  in a user name or password; crystal-db read `+` there as a space, so a password that relied on that must be written with a
  real space (`%20`).
- **Pool.** The pool is the engine's. Azu maps `CQL.config.pool` and crystal-db's `max_pool_size` (`0`, meaning unlimited there,
  becomes the default of 10), `initial_pool_size` (never above the pool size) and `checkout_timeout` for you. `prepared_statements=false`
  and `prepared_statements_cache=false` become `statement_cache_size=0` unless the URL sets it. `max_idle_pool_size`, `retry_attempts`,
  `retry_delay` and `auth_methods` are dropped: the engine does not retry connects. Behind a transaction-mode pooler (PgBouncer) use
  `statement_cache_size=0` (or `prepared_statements=false`). The rest of the URL is passed on byte for byte.
- **Shutdown.** `Azu.shutdown` closes the database pools: `Azu.on_shutdown` hooks run in reverse registration order between PubSub and Redis,
  and the pools close in the hook `azu/cql` registered when it was required, so hooks your app registers later run first. Handler
  fibers still serving a request when the server stops can meet a closed pool, as with Redis.
- **Opt out** per schema with `driver: :db` or for the app with `AZU_CQL_DRIVER=db`; crystal-db's pool and the registered driver (the
  `pg` shard if you require it) then serve the URL as before. `driver:` and `AZU_CQL_DRIVER` apply only to `Azu::CQL.schema`: a schema
  made directly with `CQL::Schema.define` or `.new` is unaffected. An unknown `AZU_CQL_DRIVER` value raises `ArgumentError` for every schema.
- **New:** `Azu::CQL.health_check(schema)`, `Azu::CQL.engine(schema)`, `Azu::CQL.shutdown`, `.track`/`.untrack`, `Azu.on_shutdown`. A schema made
  twice under the same name closes the first one.

**An endpoint declared with the bare `Azu::Request` reads its params on first use.** A JSON, multipart or other
non-urlencoded body is no longer read before `call`, so a bare-`Azu::Request` endpoint that never touches `params` no
longer answers `400` or `413` for it; a large unread body is drained by `HTTP::Server` after the handler instead of
being rejected. One that reads `params` gets the error where it asks. A `POST` with a urlencoded body is still read by
the router (for `_method`) and still answers `413` before dispatch. Endpoints with a request contract (a struct that
includes `Azu::Request`) are unchanged: they parse before `call`, except for a contract with no fields, no rules and no
methods of its own (next entry).

**A request id is cut from a buffered chunk of secure random bytes.** The format `req_<ms>_<16 hex>` is unchanged.

**A `Static` public directory created after boot is picked up within a second**, not at once, **and a top-level file
or directory added to an existing one usually within a second, at most a minute** (`Handler::Static` reads the
top-level names again when the directory's modification time or identity changes, checked once a second, and every
60 seconds regardless).

## 0.5.106

**`Azu::Env` skips many more names from a `.env` file.** The denylist is now the one the `azu` CLI uses
(`AzuCLI::DotEnv`), where it used to cover only `LD_*`, `DYLD_*`, `SHARDS_*`, `GIT_*`, `PATH`, `SHELL`, `IFS`,
`BASH_ENV`, `ENV`, `CRYSTAL_PATH`, `CRYSTAL_OPTS`, `CRYSTAL_LIBRARY_PATH`, `DOCKER_HOST` and `HOME`. It now also skips
every other `CRYSTAL_*` (but not `CRYSTAL_ENV` or `CRYSTAL_LOG_*`), `DOCKER_*`, `COMPOSE_*`, `SSH_*`, compiler and linker
variables (`CC`, `CXX`, `*FLAGS`, ...), proxy and certificate variables (`HTTP_PROXY`, `SSL_CERT_FILE`, ...), other
runtimes' variables (`PYTHON*`, `RUBY*`, `NODE_OPTIONS`, `GEM_*`, `CARGO_*`, ...), `USER`, `TMPDIR`, `XDG_*` and the
locale and time zone names `LANG`, `LC_*` and `TZ`. Matching is case-insensitive. A skipped name logs a warning naming
it (never the value) and is not set. If your `.env` sets one of them (typically `TZ` or `LANG`), set it in the real
environment instead, or load the file with `unsafe: true`. Note that `*FLAGS` also matches application names such as `FEATURE_FLAGS`, `LOG_FLAGS` and `MY_CFLAGS`: rename them (for example `FEATURES`). See [Environment](configuration/env.md#trust).

## 0.5.103

**A Redis cache needs an explicit URL, and `clear` only removes the cache's own keys.**

- `cache_config.redis_url` is now `String?` and has no default (it used to be `redis://localhost:6379/0`).
  `CACHE_STORE=redis` without `CACHE_REDIS_URL` (or `cache_config.redis_url`, or `cache_config.redis_client`) now
  raises an `ArgumentError` at `start` (`Configuration#prepare` checks it, without connecting) and on any use of
  `Azu.cache`; it is not turned into a disabled cache. Any other `ArgumentError` raised while the cache is built (an
  unknown `CACHE_STORE`) propagates the same way; only an unreachable Redis still falls back to a disabled cache.
  Set `CACHE_REDIS_URL`; to keep using localhost, say so: `CACHE_REDIS_URL=redis://localhost:6379/0`. `REDIS_URL`
  is not read by the cache.
- `Azu.cache.clear` removes the keys under `"<key_prefix>:"` instead of running `FLUSHDB`, so other keys in the same
  Redis database survive. Use `Azu.cache.clear(all: true)` for the old behaviour (`FLUSHDB`).
  `RedisStore#clear` used directly is still `FLUSHDB`. Limits of the prefix clear (cost, Redis version, Cluster):
  [Cache reference](api/cache.md).
- `Cache::Store` has a new abstract method `clear_prefix(prefix : String) : Bool`; a custom store must implement it.

## 0.5.93

**`Azu::CQL.schema` applies CQL's SQLite settings.** For a `sqlite3://` URL taken from `CQL.config`, the `c.sqlite` settings
(`journal_mode` WAL, `foreign_keys` on, `busy_timeout` 5000, ...) are appended to the URL. Before, such a schema ran with
SQLite's own defaults (foreign keys off, no busy timeout), so rows or fixtures that violate a foreign key now fail with
`FOREIGN KEY constraint failed`. Opt out with `CQL.configure { |c| c.sqlite.foreign_keys = false }`, or per URL with
`?foreign_keys=0`. See [Database dashboard](database-dashboard.md).

## 0.5.79

**Content negotiation.** New: [`Response::Negotiable`](api/content-negotiation.md). Endpoints now write their
response with `Response#write_to(context)`, which prints `render` unless the type overrides it, so existing
responses are unchanged; a hand written response type that defines its own `write_to` is now called. The
undocumented `Azu::ContentNegotiator`, which nothing called, is removed.

## 0.5.75

**Graceful shutdown of long-lived connections** (behaviour change). Open channel WebSockets are now tracked per
app: when shutdown begins each gets a close frame with code 1001, and the drain waits for the peers to answer
(within `shutdown_timeout`); before, they were neither closed nor waited for, so a client saw a dropped
connection. A socket that registers after shutdown began is closed with 1001 without `on_connect` (one registered a moment before still runs it). Streaming
responses (SSE) still count as in flight until the handler returns, but can now end promptly: `Azu.shutting_down?`
and `Azu.shutdown_signal` report the shutdown of the app serving the request. New: `App#track_socket`,
`App#shutdown_signal`, `Azu.current_app`, `Azu.with_app`. A handler that ignores the signal behaves as before.
See [Shut Down Gracefully](../how-to/deployment/graceful-shutdown.md).

## 0.5.73

**Per-app leftovers.** Building a configuration no longer applies its `i18n` settings to the process-wide
`Helpers::I18n` (`I18nConfiguration#apply` does, called when an app builds its server, and it passes on only the settings that
differ from the defaults, so an explicit `Helpers::I18n.configure` wins). Code that never reaches `App#server`
(router-only tests, a hand-built `HTTP::Server`) no longer gets `I18N_*` environment settings applied; call
`config.i18n.apply` yourself there. `Handler::Logger`,
`SimpleLogger` and `Throttle` log to the app serving the request unless given `log:`, and resolve it on every call.

## 0.5.72

**Template helpers no longer read `_session` and `_flash` cookies.** `Helpers::TemplateContext#session` and
`#flash` decoded an unsigned Base64 JSON cookie that no session library writes, so any client could forge
its session or flash. They now read through `Azu.session_adapter` (`Azu::SessionAdapter`, additive and opt-in,
stored on `Configuration#session_adapter`, no dependency on a session shard) and are empty without one. With the `session` shard (`require "session/azu"`)
install an adapter once at boot; see `docs/how-to/middleware/use-sessions.md`. Apps that wrote those cookies
themselves must move to a session store.

**CSRF token stores** (additive). `Handler::CSRF.new(token_store:)` chooses where the `SynchronizerToken` strategy
keeps its token: `CookieTokenStore` (default, unchanged) or `SessionTokenStore`, which uses
`Azu.session_adapter` so the token never reaches the client as a cookie.

**OpenAPI 3.1 generation** (additive). `Azu::OpenAPI.document(app, info)` builds the document from the
`Endpoint(Request, Response)` contracts at the time you call it, and `Azu::OpenAPI::Handler` serves it as JSON
(opt-in, like `HealthCheck`). See [the reference](api/openapi.md). `Azu::Routable` gains a default
`openapi_operation` that returns nil, `Router#registered_routes` and `Router::Mount#child` are new readers.
Nothing changes for an app that does not call it. A custom `Routable` that already defines a method named
`openapi_operation` is the only possible clash.

## 0.5.71

**Fixes** (behaviour changes that make the code do what it documented):

- `class` endpoints are request-safe. The router holds one instance per route and a class was shared by
  concurrent requests, so a request that waited (database, service) could read the parameters of a later
  one. Each request now runs on a copy (`dup`) of the registered instance, as structs always did: state an
  endpoint object keeps in its own instance variables no longer carries over from one request to the next.
- `Cache::RedisStore` returns values: `get`, `exists?`, `delete`, `increment`, `size` and `ping` always
  answered `nil`/`false`/`0`, and the start-up check turned `store = "redis"` into a `NullStore` after its
  retries. `size` counts the keys of the database in the URL (it only looked at `db0`).
- `Handler::CORS` no longer keeps the request's `Origin` in the shared handler, so overlapping requests on
  parallel threads cannot answer with each other's `Access-Control-Allow-Origin`.
  API change: `Handler::Origin` (the struct behind `CORS`) is stateless now. `#request_origin` and
  `#origin_header?` are removed, `#match?(request)` became `#match?(origin : String)`, and `#of(request)`
  returns the request's `Origin` (or `X-Origin`) header. Code that called these directly must pass the
  origin around itself.
- `Cache::MemoryStore#increment` sets the expiry when the counter is created (it was renewed on every call,
  so a counter hit more often than its TTL never expired) and evicts the least recently used key when a new
  counter would exceed `max_size`. `MemoryStore#stats["hit_rate"]` is a real hit rate (hits / lookups); it
  used to be the fill percentage. The router's `path_cache.stats` now calls its figure `fill_percent`.
- The HTML error page renders in production for unexpected exceptions (it raised "can't wrap
  Azu::ErrorContext" and the client got a bare `500`). The development JSON `Backtrace` shows the original
  exception's message and backtrace instead of ` (Azu::Response::Error)`. Production bodies still carry no
  backtrace, request context or environment, and for exceptions that are not `Response::Error` they now
  carry a generic title and detail ("Internal Server Error") instead of the exception's message (which could
  name a database host or user); the message stays in the log and in development bodies.
- `Cache::RedisStore#increment` / `#decrement` set the TTL in one atomic Lua script, only when the key has
  none; `decrement` used to renew it on every call.
- Not changed in this release: templates were not cached (`Templates#load` asked Crinja each time). They are compiled
  outside development since 0.5.113.

## 0.5.69

**The dev dashboard and performance tooling are opt-in: `require "azu/dev"`.** `require "azu"` no longer
loads them, and core no longer has the ~25 `PERFORMANCE_MONITORING` compile-time blocks. Core only calls
`Azu::Instrumentation`, which costs a nil check until `azu/dev` subscribes.

These now exist only after `require "azu/dev"` (the fix for each is the same: add that line after
`require "azu"`):

- `Azu::Handler::DevDashboard`, `Azu::Components::DevDashboardComponent` and the `Dashboard` sections
- `Azu::Handler::PerformanceMonitor`, `Azu::PerformanceMetrics`
- `Azu::PerformanceReporter`, `LogPerformanceReporter`, `JsonPerformanceReporter`,
  `PerformanceMonitoringManager`, `PerformanceReportScheduler`, `PerformanceReportService`
- `Azu::DevelopmentTools` (profiler, memory leak detector, benchmark)
- `Configuration#performance_enabled?`, `#performance_profiling_enabled?`, `#performance_memory_monitoring?`
  (and their setters), `#performance_monitor` and `#performance_monitor=`, `#development_tools`.
  `performance_profiling_enabled?` and `performance_memory_monitoring?` now follow `config.env` while
  their environment variable is unset, instead of reading the environment once when the
  configuration was built.

Other changes:

- `Azu::Cache::Manager#metrics` / `#metrics=` and the second `Manager.new` argument are gone, and so is
  `PerformanceMetrics.time_cache_operation`. With `azu/dev` loaded, cache operations are recorded in the
  current configuration's monitor whenever `performance_enabled?` is on; no per-manager wiring.
- Component and cache metrics no longer need the `PERFORMANCE_MONITORING` build flag: `azu/dev` plus
  `performance_enabled?` is enough.
- Cache and component metrics belong to the configuration of the fiber that runs the operation
  (`Azu.current_config`), not to the manager's. Start background fibers with `Azu.spawn_scoped` so they
  report to the app they serve.
- `Azu::Instrumentation` is the hook point for your own tooling: `on_cache { |operation| }`,
  `on_component { |event| }` (several subscribers can coexist; each takes an optional `enabled` predicate
  that keeps timing off while it answers false), and `on_prepare` / `on_finalize` for `Azu.start` and
  configuration teardown. A subscriber or hook that raises is logged at debug level and ignored.
- Building with `PERFORMANCE_MONITORING=true` or `-Dperformance_monitoring` still works unchanged: it makes
  `require "azu"` also load `azu/dev`.
- Files moved: `src/azu/{performance_metrics,performance_reporter,development_tools}.cr`,
  `src/azu/handler/{dev_dashboard,performance_monitor}.cr` and `src/azu/components/dev_dashboard*` are under
  `src/azu/dev/`. Require `azu/dev`, not the files.

## 0.5.64

**Graceful shutdown** (behaviour fix). On SIGTERM or SIGINT, `start` stops accepting connections and waits for
the requests in flight, up to `config.shutdown_timeout` (`SHUTDOWN_TIMEOUT` seconds, default 30), before it
shuts the rest down. It traps `TERM` as well as `INT`, and then calls `Azu.shutdown`. Before, it exited as soon as the
listener closed. The restart branch of the server loop
(`e == Errno`) could never run and is gone: a failure of the listener is logged and `start` returns.
`Azu::App#stop(timeout)` does the same from code and specs (bind the server on `bind_unused_port`).
Requests that arrive on connections that stay open after the listener closed get `503` with `Connection: close`.
Only `App.default` is drained by `start`.

## 0.5.63

**A default handler stack** (additive). `MyApp.start` without arguments serves
`RequestId, Logger, Rescuer, SecurityHeaders, Static` (`Azu::App#default_handlers`). Passing an array
keeps today's behaviour exactly: it is used as given and nothing is added to it.

- `Handler::SecurityHeaders`: `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`; HSTS and a
  `Content-Security-Policy` only when asked for (`hsts: true`, `content_security_policy: "..."`). Headers
  the application already set are left alone.
- `Handler::Compression`: gzip/deflate, the standard library's `HTTP::CompressHandler`. Opt-in, and not in the
  default stack: `Static` already compresses and sets its own `Content-Length`, so put `Compression` only
  in front of the router (after `Static`), not in front of `Static`.
- `Handler::HealthCheck`: opt-in, not in the default stack. `GET /health` (or `HEAD`) answers `200`, or `503`
  naming the failing checks, without reaching the router.
- The default stack includes `Static` serving `./public` relative to the working directory, with
  `fallthrough: true`. A file there shadows a route with the same path, and anything in `public/` is
  served, so keep only public files in it. HSTS follows `config.tls?`; behind a TLS-terminating proxy pass
  your own `SecurityHeaders.new(hsts: true)`.

## 0.5.62

**Request contracts are enforced.** An endpoint whose request type has validations no longer runs when the
request breaks them: the endpoint answers `422` before `call` (by itself, whether or not a `Rescuer` is in the handler stack),
and the parsed request is built once per call.

- The body is RFC 7807 `application/problem+json`:
  `{"type": "about:blank", "title": "Validation Error", "status": 422, "detail": "...", "errors": {"name": ["must be present"]}}`.
- To keep the pre-0.6 body (`FieldErrors`, `ErrorId`, ...) for one more minor release, set
  `config.error_format = Azu::ErrorFormat::Legacy`.
- The request is parsed before `call` even when the endpoint never reads it, so a body that cannot be parsed
  into the request type (for example a missing non-nilable field on a GET) answers `400` before `call`, also
  without a `Rescuer`.
  Endpoints that validate by hand (`if signup_request.valid?` then re-render a form) no longer get to run
  for invalid input; declare such an endpoint with a request type without validations.
- Endpoints declared with the bare `Azu::Request` module have no contract and are not affected, and neither is a
  contract identical to it, for a request without a `Content-Type` (since 0.5.119).

## 0.5.61

**Routes can belong to an app** (additive; the endpoint macros keep registering on `Azu::App.default`). The
macros now record their routes on the endpoint type (`.routes`) and `App.default` registers them lazily, the first
time its router is read, instead of when the class body runs; `Router::Builder#endpoint(Type)` registers a type on any
other app. Observable differences: a duplicate route raises when the router is first used (`App#server` and
`Azu.start` do it at boot) rather than at class definition, and code that reads `Azu::CONFIG.router` still sees every
declared route because the router getter applies them.

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

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("user")
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(Azu::Request, TextResponse)

  def call : TextResponse
    TextResponse.new("created")
  end
end

admin_app = Azu::App.new

app = Azu::App.new
app.routes do
  get "/users/:id", UserEndpoint
  scope "/api" do
    post "/users", CreateUserEndpoint
  end
  mount admin_app, at: "/admin"
end
```

- `scope` really prefixes now (`Router::Builder` used to ignore its scope).
- `mount` serves another app below a prefix with that app's own router and configuration. An app can be
  mounted once; build one app per mount.
- `Endpoint.path` includes the prefix the app is mounted at and the scope the route was declared in,
  so links stay right wherever the endpoint is mounted. A link to an endpoint another app routes is
  returned without any prefix.
- `Router#routes { }` now yields `Router::Builder`, which declares verbs, `ws`, `scope` and `mount`; it no
  longer forwards other calls (`root`, `add`) to the router.

## 0.5.59

**Requiring `azu` no longer starts anything.** Before, `require "azu"` set the root `Log` level to `Debug`
with Azu's formatter, created the upload temp directory and started seven background fibers.

- Logging: neither `require "azu"` nor `start` configures `Log` any more, so an app that sets up `Log`
  itself keeps its backend and level. To get the previous Azu format at `Debug`, call
  `Azu.setup_logging` once at boot (before `start`).
- The async log pipeline starts on the first log entry or reported error, or in `start`.
- The upload temp directory and its cleanup task are created by `start` (or by the first upload for
  apps that never call `start`).
- The profiler and memory monitor (`azu/dev`) that development mode turns on by default now start in `start`
  instead of when the configuration is built.

## 0.5.48

**Spark replaces the Preact/jQuery client; channels check origins and sizes.**

- `Azu::Spark` is a module. `ComponentRegistry`, `Spark.javascript_tag`, the `live-*` attribute protocol and the
  `spark_tag()`, `live_click`, `live_change`, `live_input` and `live_value` template helpers are removed. Use
  `Azu::Spark.script_tag` and the binding macros (`spark_click`, ...); see [Spark JavaScript client](spark-client.md).
- `Azu::Component` is a static `Markup` component: `mount`, `every`, `on_event` and `refresh` are removed. Stateful
  components inherit `Azu::Spark::Component` (see [Component](api/component.md)).
- `Markup` omits `disabled: false` and renders `disabled: true` as a bare attribute (the same for the other boolean
  attributes, such as `checked` and `required`).
- Channels refuse cross-origin browser upgrades with `403`. Behind a proxy that rewrites `Host`, list the public
  origin in `WEBSOCKET_ALLOWED_ORIGINS`.
- A message over 1 MB closes the connection (`CloseCode::MessageTooBig`), and the server pings every 30 seconds
  (`websocket.ping_interval`).
- `Channel#initialize` sets up mutexes: a subclass that overrides it must call `super`.
- New `Channel` methods (`context`, `params`, `headers`, `send`, `close`, `subscribe`, `broadcast`) may clash with
  methods of the same name in subclasses.
- `Router#ws` registers a `Channel::Upgrader`, so the `Route#endpoint` of a WebSocket route is the upgrader, not the
  channel (`route_info["handler"]` names the channel class).

**Fixes** (behaviour changes that make the code do what it documented):

- `class` endpoints are request-safe. The router holds one instance per route and a class was shared by
  concurrent requests, so a request that waited (database, service) could read the parameters of a later
  one. Each request now runs on a copy (`dup`) of the registered instance, as structs always did: state an
  endpoint object keeps in its own instance variables no longer carries over from one request to the next.
- `Cache::RedisStore` returns values: `get`, `exists?`, `delete`, `increment`, `size` and `ping` always
  answered `nil`/`false`/`0`, and the start-up check turned `store = "redis"` into a `NullStore` after its
  retries. `size` counts the keys of the database in the URL (it only looked at `db0`).
- `Handler::CORS` no longer keeps the request's `Origin` in the shared handler, so overlapping requests on
  parallel threads cannot answer with each other's `Access-Control-Allow-Origin`.
  API change: `Handler::Origin` (the struct behind `CORS`) is stateless now. `#request_origin` and
  `#origin_header?` are removed, `#match?(request)` became `#match?(origin : String)`, and `#of(request)`
  returns the request's `Origin` (or `X-Origin`) header. Code that called these directly must pass the
  origin around itself.
- `Cache::MemoryStore#increment` sets the expiry when the counter is created (it was renewed on every call,
  so a counter hit more often than its TTL never expired) and evicts the least recently used key when a new
  counter would exceed `max_size`. `MemoryStore#stats["hit_rate"]` is a real hit rate (hits / lookups); it
  used to be the fill percentage. The router's `path_cache.stats` now calls its figure `fill_percent`.
- The HTML error page renders in production for unexpected exceptions (it raised "can't wrap
  Azu::ErrorContext" and the client got a bare `500`). The development JSON `Backtrace` shows the original
  exception's message and backtrace instead of ` (Azu::Response::Error)`. Production bodies still carry no
  backtrace, request context or environment, and for exceptions that are not `Response::Error` they now
  carry a generic title and detail ("Internal Server Error") instead of the exception's message (which could
  name a database host or user); the message stays in the log and in development bodies.
- `Cache::RedisStore#increment` / `#decrement` set the TTL in one atomic Lua script, only when the key has
  none; `decrement` used to renew it on every call.
- Not changed in this release: templates were not cached (`Templates#load` asked Crinja each time); see "Templates are preloaded outside development" under Unreleased.

**Content negotiation.** New: [`Response::Negotiable`](api/content-negotiation.md). Endpoints now write their
response with `Response#write_to(context)`, which prints `render` unless the type overrides it, so existing
responses are unchanged; a hand written response type that defines its own `write_to` is now called. The
undocumented `Azu::ContentNegotiator`, which nothing called, is removed.

### 0.5.28

**No breaking changes.** This version includes documentation improvements.

### 0.5.0

**Endpoint Type Parameters**

The `Endpoint` module now requires explicit type parameters:

```text
# Before (0.4.x)
struct MyEndpoint
  include Azu::Endpoint

  def call
    # ...
  end
end

# After (0.5.x)
struct MyEndpoint
  include Azu::Endpoint(MyRequest, MyResponse)

  def call : MyResponse
    # ...
  end
end
```

**Migration:**
1. Add request type as first parameter (use `Azu::Request` for no body)
2. Add response type as second parameter
3. Add return type annotation to `call`

An `Azu::Endpoint` without type parameters no longer compiles.

**Request Access**

Request objects are now accessed via generated methods:

```text
# Before
request.name

# After
my_request.name  # Method name derived from request type
create_user_request.name  # For CreateUserRequest
```

## 0.4.0

**Handler Interface**

Handlers now use `call_next` instead of `next.try &.call`:

```text
# Before (0.3.x)
def call(context)
  # ...
  next.try &.call(context)
end

# After (0.4.x)
def call(context)
  # ...
  call_next(context)
end
```

**Configuration**

Configuration moved from class methods to block syntax:

```text
# Before (0.3.x)
Azu.port = 8080
Azu.env = :production

# After (0.4.x)
Azu.configure do |config|
  config.port = 8080
  config.env = Environment::Production
end
```

## 0.3.0

**Router Changes**

Route registration moved to macros:

```text
# Before (0.2.x)
Azu.router.add("GET", "/users", UsersEndpoint)

# After (0.3.x)
struct UsersEndpoint
  include Azu::Endpoint

  get "/users"  # Route defined with macro

  def call
    # ...
  end
end
```

**Response Objects**

Responses now implement `Azu::Response` module:

```text
# Before (0.2.x)
def call
  {users: users}.to_json
end

# After (0.3.x)
struct UsersResponse
  include Azu::Response

  def render
    {users: @users}.to_json
  end
end
```

## 0.2.0

**WebSocket Channels**

Channel API changed from callback-based to method-based:

```text
# Before (0.1.x)
Azu.channel("/chat") do |socket, message|
  # Handle message
end

# After (0.2.x)
class ChatChannel < Azu::Channel
  PATH = "/chat"

  def on_message(message)
    # Handle message
  end
end
```

## Crystal versions

### Deprecated in 0.5.x

- Implicit request types - Always specify request type parameter
- The template preload names of 0.5.113 to 0.5.133: `Templates#compiled?`, `Templates#compile_ignore`, the
  `compile_ignore:` keyword, `Configuration#template_compile_ignore` and `TEMPLATE_COMPILE_IGNORE` (see "Templates are
  preloaded outside development")

### Removed in 0.5.x

- `Azu::Endpoint` without type parameters

## Migration Tools

### Checking for Deprecations

Apps that stay on Crystal 1.19.1 must use Azu 0.5.123 or older and a CQL release that compiles on 1.19.1 (0.0.766 or older,
or 0.0.879 or newer; 0.0.798 and 0.0.808 do not compile on 1.19.1). Pin it in your own `shard.yml`, for example
`cql: '>= 0.0.609, < 0.0.798'`.

Azu 0.5.124 and newer declare `crystal: '>= 1.22.1'`. `shards install` does not refuse on an older compiler: it prints
`W: Shard "azu" may be incompatible with Crystal 1.19.1` and installs anyway (it warns for a dependency's `crystal:` line and
never enforces the `crystal:` line of your own `shard.yml`). The specs and CI run on 1.22.1 and newer only, so
0.5.124 and newer is unsupported on older compilers, whatever the warning lets through.

### Unreleased (0.6 work)

Step by step, with old and new code side by side: [Migrate to 0.6](../how-to/migrate-to-0.6.md).

| Azu Version | Crystal Version |
|-------------|-----------------|
| 0.5.x | 1.22.1 and newer (tested on 1.22.1 and the latest release; releases up to 0.5.123 asked for 1.19.1) |
| 0.4.x | 0.35.0 - 1.0.0 |
| 0.3.x | 0.35.0 - 0.36.x |

## See also

- [Migrate to 0.6](../how-to/migrate-to-0.6.md)
- [Configuration options](configuration/options.md)
- [Releases on GitHub](https://github.com/azutoolkit/azu/releases)

# Breaking Changes

This document lists breaking changes between Azu versions and migration guides.

## Version 0.5.x

### Unreleased (0.6 work)

Step by step, with old and new code side by side: [Migrate to 0.6](../how-to/migrate-to-0.6.md).

**The router matches only exact HTTP methods and paths that start with `/` (security fix: upgrade).** A request whose
method is not one of the verbs spelled exactly (`GET`, `POST`, ...: methods are case-sensitive, so `get` is not `GET`) or
whose path does not start with `/` answers `404`, and a WebSocket route is reached only by a `GET` upgrade. The route a
request reaches is now always the one its `request.method` and `request.path` name, which handlers before the router rely
on. Clients that send the standard verbs in upper case see no change; a client that sends one in lower case
(`fetch(url, {method: "patch"})` sends `patch`, as does `curl -X patch`) must send `PATCH`.
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

**Template helpers escape what they used to pass through (security).** `highlight` and `content_tag` escape their text and
content (pass markup as a `SafeString`: another helper's output or `| safe`); `link_to`, `button_to` and `form_tag` replace a
URL whose scheme is not `http`, `https`, `mailto` or `tel` (`javascript:`, `data:`, `vbscript:`, ...) with `#` or
`about:invalid`; an attribute name that is not `[A-Za-z_:][-A-Za-z0-9_:.]*` is dropped and a tag name that is not a name
raises `ArgumentError`. Check `content_tag(content="<b>x</b>")` and links to other schemes (`sms:`, `ftp:`, custom app schemes):
write those `<a>` tags yourself. See [attribute names and URLs](templates/helpers.md#attribute-names-and-urls).

**`Static` can refuse paths (additive, nothing to change).** `Azu::Handler::Static.new(except: ["/templates"])` never serves
`/templates` or anything below it; the request goes to the next handler, or answers `404` with `fallthrough: false`. Without
`except` the handler behaves as before. Use it when template sources live under `public/`:

```crystal
Azu::Handler::Static.new("public", except: ["/templates"])
```

`except` is the supported way to keep paths under `public/` from being served. See [Handler::Static](handlers/built-in.md#handlerstatic).

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

**Templates are compiled outside development.** With `template_hot_reload` off (the default for `staging`,
`production` and any environment other than `development`, `test` and `pipeline`), `Azu.prepare` reads and parses
every template once and requests no longer read template files: an edit to a template file needs a restart, where
before it showed on the next request, and a template with a syntax error now stops the boot (with its name and
line) instead of failing its first request, including a file that is not a template (a vendored `index.html`; list
those in `template_compile_ignore`). Set `template_hot_reload = true` (or `TEMPLATE_HOT_RELOAD=true`) to keep
reloading in an environment. See [Configuration](configuration/options.md#templates).

**`Router#path_cache` is internal.** It is `:nodoc:` and its `get`/`set` now take the method and the path
(`get("GET", "/x")`) instead of one `"GET:/x"` key; `path_cache.stats` and `clear_path_cache` are unchanged. Nothing
outside the router should call `get` or `set`.

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

**`Handler::Static` redirects to the right path.** The redirect for a directory requested without its trailing slash answered
`Location: /subdir//` (two slashes), and one for a path that was not in its normal form (`/a/../b.txt`) answered `/b.txt/` (a slash added to a
file). Now `/subdir` redirects to `/subdir/`, `/a/../b.txt` to `/b.txt`, and the query string is kept. A
path-only `Location` starts with exactly one `/`, so `//evil.com` is redirected to `/evil.com`, never to a protocol-relative URL.
**Azu's error pages no longer depend on the working directory.** `error.html` and `error_debug.html` are compiled into
the binary (`Azu::Templates::BUILTIN`), and `ERROR_TEMPLATE` defaults to the directory they live in inside the azu source
(resolved at compile time) instead of `./src/azu/templates`. Before, an app that installed azu as a shard found no
error template unless it ran from a checkout of azu, so the production HTML error page raised
`Crinja::TemplateNotFoundError`. The lookup order is now your `templates.path` directories, then `ERROR_TEMPLATE`, then the
built-in pages (before: `ERROR_TEMPLATE` first), so an `error.html` in your own template directory now overrides the
built-in one. `TEMPLATES_PATH` is unchanged: it is for your templates and a relative entry is still resolved against the
working directory, so run the app from its root or set an absolute path.
`Templates#crinja.loader` is a `Crinja::Loader::ChoiceLoader` now, not a `FileSystemLoader`. The built-in pages are autoescaped like the file based ones, an `error.html` of yours that fails to render falls back to the built-in page, and a debug log line names an `error.html` that replaces a built-in one.

**`Azu::Env` skips many more names from a `.env` file.** The denylist is now the one the `azu` CLI uses
(`AzuCLI::DotEnv`), where it used to cover only `LD_*`, `DYLD_*`, `SHARDS_*`, `GIT_*`, `PATH`, `SHELL`, `IFS`,
`BASH_ENV`, `ENV`, `CRYSTAL_PATH`, `CRYSTAL_OPTS`, `CRYSTAL_LIBRARY_PATH`, `DOCKER_HOST` and `HOME`. It now also skips
every other `CRYSTAL_*` (but not `CRYSTAL_ENV` or `CRYSTAL_LOG_*`), `DOCKER_*`, `COMPOSE_*`, `SSH_*`, compiler and linker
variables (`CC`, `CXX`, `*FLAGS`, ...), proxy and certificate variables (`HTTP_PROXY`, `SSL_CERT_FILE`, ...), other
runtimes' variables (`PYTHON*`, `RUBY*`, `NODE_OPTIONS`, `GEM_*`, `CARGO_*`, ...), `USER`, `TMPDIR`, `XDG_*` and the
locale and time zone names `LANG`, `LC_*` and `TZ`. Matching is case-insensitive. A skipped name logs a warning naming
it (never the value) and is not set. If your `.env` sets one of them (typically `TZ` or `LANG`), set it in the real
environment instead, or load the file with `unsafe: true`. Note that `*FLAGS` also matches application names such as `FEATURE_FLAGS`, `LOG_FLAGS` and `MY_CFLAGS`: rename them (for example `FEATURES`). See [Environment](configuration/env.md#trust).

**An endpoint declared with the bare `Azu::Request` reads its params on first use.** A JSON, multipart or other
non-urlencoded body is no longer read before `call`, so a bare-`Azu::Request` endpoint that never touches `params` no
longer answers `400` or `413` for it; a large unread body is drained by `HTTP::Server` after the handler instead of
being rejected. One that reads `params` gets the error where it asks. A `POST` with a urlencoded body is still read by
the router (for `_method`) and still answers `413` before dispatch. Endpoints with a request contract (a struct that
includes `Azu::Request`) are unchanged: they parse before `call`, except for a contract with no fields, no rules and no
methods of its own (next entry).

**A contract identical to a bare `include Azu::Request` is not parsed or checked for a request without a `Content-Type`.**
Only a contract with no fields, no `validate`/`use` rules and no methods of its own skips it; its params are read on
first use, as for the bare `Azu::Request`. A request with a `Content-Type` is parsed and checked as before, and so is
every request to a contract with fields, with rules (its own or inherited) or with any method of its own: its own
`errors`, a constructor such as `from_www_form` or `initialize`, or any other.

**`HTTP::Request#path_params=` takes a `Hash(String, String)`** (it was untyped), and `path_params` is allocated on first
read. `Router#process` returns `""` for a routed request instead of the rendering of the context.

**A request id is cut from a buffered chunk of secure random bytes.** The format `req_<ms>_<16 hex>` is unchanged.

**A `Static` public directory created after boot is picked up within a second**, not at once, **and a top-level file
or directory added to an existing one usually within a second, at most a minute** (`Handler::Static` reads the
top-level names again when the directory's modification time or identity changes, checked once a second, and every
60 seconds regardless).

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

**`Handler::Static.new` falls through by default.** `fallthrough` defaulted to `false`, so a `Static` placed before the
router answered `404` for every path that is not a file and `405` for every `POST`, hiding all the routes; only the default
stack (`fallthrough: true`) worked. The default is now `true`: a request that is not a `GET`/`HEAD` for an existing file goes to the next
handler. Code that relied on the old default as the last handler of a chain (to answer 404/405 itself) must pass
`fallthrough: false`; passing `fallthrough: true` explicitly, as the docs and the default stack do, changes nothing.
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
**`Vary` fields are compared as whole tokens.** `CORS`, `Static` and `Negotiation` add their fields through one helper that splits every `Vary` line on commas and compares
trimmed tokens case-insensitively, so `Vary: Accept-Encoding` no longer hides `Accept` and `X-Origin` no longer hides `Origin`. A `Vary: *` is left untouched (`Negotiation`
used to extend it). The fields are written as one comma list. `Compression` sets no `Vary: Accept-Encoding` itself (out of scope here). A subclass of `Throttle::Refusal` is
treated like any error you raise: it shares neither the page cache nor the fingerprint of Throttle's own refusal.

**`include Azu` is a supported facade, and `Azu::App` can start itself.** `include Azu`, `configure` and `Azu::CONFIG`
are the single-app facade (global configuration, one app per process); they are not deprecated and log no warning.
`Azu.warn_global_shim` and `Azu.reset_shim_warning` are gone (nothing calls them). `Azu::App#start` serves an app built as
a value with the lifecycle the facade used (prepare, bind, SIGINT/SIGTERM, drain, `Azu.shutdown`), and `MyApp.start` is now
`Azu::App.default.start`, one code path. New: `App#start(handlers, signals:, teardown:)`, `#running?`, `#address`,
`#prepare`, `App::AlreadyRunning`. An app starts **once**: `start` on a running app raises `AlreadyRunning`, on one that has stopped (or begun to shut down)
`AlreadyStopped`; build a new `Azu::App` to serve again (a `start` that failed to bind can be repeated, the same handlers
included). Differences for facade users: `start` on a stopped `App.default` raises; a SIGINT/SIGTERM now stops every app started with `start`; `Azu.shutdown` runs when the last of them stops.
Reference: [App](api/app.md).

**Per-app leftovers.** Building a configuration no longer applies its `i18n` settings to the process-wide
`Helpers::I18n` (`I18nConfiguration#apply` does, called when an app builds its server, and it passes on only the settings that
differ from the defaults, so an explicit `Helpers::I18n.configure` wins). Code that never reaches `App#server`
(router-only tests, a hand-built `HTTP::Server`) no longer gets `I18N_*` environment settings applied; call
`config.i18n.apply` yourself there. `Handler::Logger`,
`SimpleLogger` and `Throttle` log to the app serving the request unless given `log:`, and resolve it on every call.

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

**The development error context redacts credentials.** `Azu::ErrorContext` (the request/process data an error carries in development and
puts in the JSON, text and `error_debug.html` pages) used to hold the whole process environment and the raw request headers. The
environment is now `Azu::Env.redacted(ENV.to_h)` (values of names such as `*_SECRET`, `*_TOKEN`, `*_KEY`, `*PASSWORD*`, `*COOKIE*`, `*AUTH*` become
`[FILTERED]`, and the password of a `scheme://user:password@host` URL is hidden), the header values of `Authorization`, `Cookie`, `Set-Cookie`,
`X-CSRF-Token`, `X-API-Key` and the like are `[FILTERED]` in `to_h`/`to_json` (`ErrorContext#headers` is still the real request headers; use
`#redacted_headers` for display), and query parameters with such names are redacted in `#redacted_params`. If you read a secret value out of an
error JSON in development, read it from the environment instead. `Azu::Env.redact` also filters names with `PASS`, `PWD`, `JWT`, `SESSION`, `SID`, `SIGNATURE`, `CONNECTION_STRING`, `OTP`, `PIN`, `CVV`, `CARD`, `SSN` (hyphenated header names count like underscored ones), and the new `Azu::Env.redact_url` hides URL passwords and credential query parameters (`?token=...`) anywhere in a value (referer, endpoint). The development exception page (the `exception_page` shard) is built from redacted query parameters, response headers and response cookies.

**Template helpers no longer read `_session` and `_flash` cookies.** `Helpers::TemplateContext#session` and
`#flash` decoded an unsigned Base64 JSON cookie that no session library writes, so any client could forge
its session or flash. They now read through `Azu.session_adapter` (`Azu::SessionAdapter`, additive and opt-in,
stored on `Configuration#session_adapter`, no dependency on a session shard) and are empty without one. With the `session` shard (`require "session/azu"`)
install an adapter once at boot; see `docs/how-to/middleware/use-sessions.md`. Apps that wrote those cookies
themselves must move to a session store.

**CSRF token stores** (additive). `Handler::CSRF.new(token_store:)` chooses where the `SynchronizerToken` strategy
keeps its token: `CookieTokenStore` (default, unchanged) or `SessionTokenStore`, which uses
`Azu.session_adapter` so the token never reaches the client as a cookie.

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
  contract identical to it, for a request without a `Content-Type` (see the entry above).

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

**OpenAPI 3.1 generation** (additive). `Azu::OpenAPI.document(app, info)` builds the document from the
`Endpoint(Request, Response)` contracts at the time you call it, and `Azu::OpenAPI::Handler` serves it as JSON
(opt-in, like `HealthCheck`). See [the reference](api/openapi.md). `Azu::Routable` gains a default
`openapi_operation` that returns nil, `Router#registered_routes` and `Router::Mount#child` are new readers.
Nothing changes for an app that does not call it. A custom `Routable` that already defines a method named
`openapi_operation` is the only possible clash.

**Graceful shutdown** (behaviour fix). On SIGTERM or SIGINT, `start` stops accepting connections and waits for
the requests in flight, up to `config.shutdown_timeout` (`SHUTDOWN_TIMEOUT` seconds, default 30), before it
shuts the rest down. Before, it exited as soon as the listener closed. The restart branch of the server loop
(`e == Errno`) could never run and is gone: a failure of the listener is logged and `start` returns.
`Azu::App#stop(timeout)` does the same from code and specs (bind the server on `bind_unused_port`).
Requests that arrive on connections that stay open after the listener closed get `503` with `Connection: close`.
Only `App.default` is drained by `start`.

**Graceful shutdown of long-lived connections** (behaviour change). Open channel WebSockets are now tracked per
app: when shutdown begins each gets a close frame with code 1001, and the drain waits for the peers to answer
(within `shutdown_timeout`); before, they were neither closed nor waited for, so a client saw a dropped
connection. A socket that registers after shutdown began is closed with 1001 without `on_connect` (one registered a moment before still runs it). Streaming
responses (SSE) still count as in flight until the handler returns, but can now end promptly: `Azu.shutting_down?`
and `Azu.shutdown_signal` report the shutdown of the app serving the request. New: `App#track_socket`,
`App#shutdown_signal`, `Azu.current_app`, `Azu.with_app`. A handler that ignores the signal behaves as before.
See [Shut Down Gracefully](../how-to/deployment/graceful-shutdown.md).

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
- Not changed in this release: templates were not cached (`Templates#load` asked Crinja each time); see "Templates are compiled outside development" under Unreleased.

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
1. Add request type as first parameter (use `EmptyRequest` for no body)
2. Add response type as second parameter
3. Add return type annotation to `call`

**Request Access**

Request objects are now accessed via generated methods:

```text
# Before
request.name

# After
my_request.name  # Method name derived from request type
create_user_request.name  # For CreateUserRequest
```

## Version 0.4.x

### 0.4.0

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

## Version 0.3.x

### 0.3.0

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

## Version 0.2.x

### 0.2.0

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

## Deprecation Notices

### Deprecated in 0.5.x

- `Azu::Handler::Base#next` - Use `call_next(context)` instead
- Implicit request types - Always specify request type parameter

### Removed in 0.5.x

- `Azu::Endpoint` without type parameters
- `Azu.start` without handler array

## Migration Tools

### Checking for Deprecations

Run the compiler in strict mode:

```bash
crystal build --warnings=all src/app.cr
```

### Version Compatibility

| Azu Version | Crystal Version |
|-------------|-----------------|
| 0.5.x | 1.22.1 and newer (CI runs 1.22.1 and the latest release; releases up to 0.5.123 asked for 1.19.1) |
| 0.4.x | 0.35.0 - 1.0.0 |
| 0.3.x | 0.35.0 - 0.36.x |

## Getting Help

If you encounter issues during migration:

1. Check the [GitHub Issues](https://github.com/azutopia/azu/issues)
2. Review the [CHANGELOG](https://github.com/azutopia/azu/blob/master/CHANGELOG.md)
3. Ask in the [Crystal Forum](https://forum.crystal-lang.org/)

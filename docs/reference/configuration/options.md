---
description: "Every option of `Azu::Configuration`, with its type, default and environment variable."
---

# Configuration options

`Azu::Configuration` holds the settings of an app: its server, environment, templates, uploads, WebSockets, cache,
i18n, assets and database instrumentation. It comes with `require "azu"`; the global one is `Azu::CONFIG`, and every
`Azu::App` has its own. Most options read an environment variable when the configuration is built. Spark has
[its own page](spark.md), and `.env` files and secrets belong to [`Azu::Env`](env.md).

A module that includes `Azu` gets `configure`, which yields the global configuration, `Azu::CONFIG`:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.port = 8080
    config.env = Azu::Environment::Production
    config.shutdown_timeout = 10.seconds
  end
end
```

`Azu::CONFIG` is also what `Azu::App.default.config` returns. An app of your own has its own configuration:

```crystal
require "azu"

app = Azu::App.new
app.config.port = 4100
app.config.env = Azu::Environment::Test
```

Code running inside a request sees the configuration of the app that serves it through `Azu.current_config`.

{% hint style="warning" %}
Defaults are read when the configuration object is built, which for the global one happens when `azu` is required,
so set environment variables before that (or assign in code).
{% endhint %}

## Options

### Server

| Option | Type | Default | Environment |
|---|---|---|---|
| `port` | `Int32` | `4000` | `PORT` |
| `host` | `String` | `"127.0.0.1"` in development, `"0.0.0.0"` in every other environment | `HOST` |
| `port_reuse?` | `Bool` | `true` | `PORT_REUSE` (`"true"` enables) |
| `shutdown_timeout` | `Time::Span` | `30.seconds` | `SHUTDOWN_TIMEOUT` (seconds, never below 0) |
| `container?` | `Bool` | detected: `/.dockerenv` or `/run/.containerenv` exists, or `KUBERNETES_SERVICE_HOST` is set | `KUBERNETES_SERVICE_HOST` (any non-blank value) |

`host` is read when the server starts: `HOST` or `config.host=` wins, `0.0.0.0` included; without one the address depends on
the environment (loopback in development, see [Environments](environments.md#the-default-environment)). When
`container?` is true, `App#start` warns that a server listening on a loopback address cannot be reached from outside
the container.

`port_reuse` sets `SO_REUSEPORT` on the listener, which lets several processes share one port. On SIGTERM or SIGINT
`start` stops accepting connections and waits up to `shutdown_timeout` for requests in flight; new requests on open
connections get `503` with `Retry-After: 1`, open WebSockets are closed with 1001 (going away) and streaming handlers
see `Azu.shutting_down?`; see [Shut Down Gracefully](../../how-to/deployment/graceful-shutdown.md).

```crystal
require "azu"

Azu::CONFIG.port = 8080
Azu::CONFIG.port_reuse = false
```

### TLS

| Option | Type | Default | Environment |
|---|---|---|---|
| `ssl_cert` | `String` | `""` | `SSL_CERT` |
| `ssl_key` | `String` | `""` | `SSL_KEY` |
| `ssl_ca` | `String` | `""` | `SSL_CA` |
| `ssl_mode` | `String` | `"none"` | `SSL_MODE` (OpenSSL `verify_mode`) |

`tls?` is true when both `ssl_cert` and `ssl_key` are set, and `start` then binds with TLS.
(`SecurityHeaders` in the default stack sends HSTS exactly then.) There is no `ssl` or `reuse_port` option.

```crystal
require "azu"

Azu::CONFIG.ssl_cert = "/etc/ssl/app.pem"
Azu::CONFIG.ssl_key = "/etc/ssl/app.key"
```

### Environment

`env` is an `Azu::Environment` (`Build`, `Development`, `Test`, `Integration`, `Acceptance`, `Pipeline`, `Staging`,
`Production`), read from `CRYSTAL_ENV` (case-insensitive) and `Development` when unset. An unknown value raises
`ArgumentError: Unknown enum Azu::Environment value` when the configuration is built. `AZU_ENV` is not read.
What each environment changes is on the [environments page](environments.md).

```crystal
require "azu"

Azu::CONFIG.env = Azu::Environment::Production
puts Azu::CONFIG.env.production?
```

### Logging

| Option | Type | Default |
|---|---|---|
| `log` | `Log` | `Log.for("Azu")` |

`log` is the logger the framework writes to (request lines of `Handler::Logger`, cache and upload messages). The
level and the backend belong to Crystal's `Log`: there is no `log.level` or `log.backend` option. Set them with
`Log.setup`, or call `Azu.setup_logging` for Azu's format at `Debug`. See
[Add logging](../../how-to/middleware/add-logging.md).

```crystal
require "azu"

Azu::CONFIG.log = Log.for("my_app")
```

### Templates

| Option | Type | Default | Environment |
|---|---|---|---|
| `template_hot_reload?` | `Bool` | `true` for `development`, `test` and `pipeline`, else `false` | `TEMPLATE_HOT_RELOAD` |
| `template_autoescape?` | `Bool` | `true` | `TEMPLATE_AUTOESCAPE` (`false` turns it off; a value other than `true` keeps it on and `App#start` logs a warning) |
| `template_compile_ignore` | `Array(String)` | `[]` | `TEMPLATE_COMPILE_IGNORE` (comma separated globs) |
| `templates.path` | `Array(String)` | the working directory's `../../templates` | `TEMPLATES_PATH` (comma separated) |
| `templates.error_path` | `String` | the error templates inside the azu source (compile-time path) | `ERROR_TEMPLATE` |

`templates` is the configuration's `Azu::Templates`, built on first use from these options. `templates.path = "..."`
**adds** a directory to the list. Assigning `template_hot_reload`, `template_autoescape` or `template_compile_ignore`
also changes templates that were built already; the default of `template_hot_reload` is read from `CRYSTAL_ENV` when
the configuration is built, so assigning `config.env` afterwards does not change it. What each option does
(reloading, compiling at boot, escaping) is on [Templates and Renderable](../templates/renderable.md).
`template_autoescape` makes `.jinja`, `.j2` and string templates escape `{{ }}` output like `.html` (Crinja alone only
escapes `html`, `htm` and `xml`). Templates of other formats (`*.txt`, `*.json.jinja`, `*.md.jinja`, ... see [breaking changes](../breaking-changes.md)) are not
escaped. `App#start` logs a warning while `template_autoescape` is off. Turn it off
only for an app that cannot be migrated yet: `Azu::CONFIG.template_autoescape = false`, or `TEMPLATE_AUTOESCAPE=false`; any
other value of the variable keeps it on. It applies to preloaded templates too, because Crinja decides at render time.

The default template path resolves relative to the working directory, so set `TEMPLATES_PATH`
or add your directory (relative entries are resolved against the working directory, so run the app from its root).
Azu's own `error.html` and `error_debug.html` are compiled into the binary and found from any working directory;
an `error.html` in your template directories overrides them. `templates.path = "..."` **adds** a directory to the list:

```crystal
require "azu"

Azu::CONFIG.templates.path = "./public/templates"
Azu::CONFIG.template_hot_reload = false
```

With hot reload on, `templates` re-reads template files that changed (it checks at most once a second). With it off
the templates are **preloaded**: `Azu.prepare` (which `App#start` calls) finds every `*.html`, `*.jinja` and `*.j2`
file below the template directories, reads and parses each once, and a request only looks the parsed template up
by name. Nothing is read from disk per request, so an edit to a template file needs a restart. A template with a
syntax error stops the start, with its name and line, instead of failing its first request (an app `error.html`
that does not parse is the exception: the built-in page is used). A file added after the preload is still
found, by the file loader. Without `Azu.prepare` the preload happens on the first render.

| Environment | Templates |
|---|---|
| `development` | reload (modification time checked at most once a second) |
| `test`, `pipeline` | reload, so specs can write templates while running |
| `staging`, `production`, any other | preloaded |
| `build`, `integration`, `acceptance` | preloaded (only `development`, `test` and `pipeline` reload) |
| `template_hot_reload` / `TEMPLATE_HOT_RELOAD` set | wins over the environment, e.g. reload in staging |

The default is read from `CRYSTAL_ENV` when the configuration is built; assigning `config.env = ...` afterwards does
not change it. Assigning `config.template_hot_reload = ...` does, also for templates that were built already. All
preloaded templates stay in memory, and a template mounted from a volume or ConfigMap needs a restart to change.

**Files that are not templates.** Every `*.html`, `*.jinja` and `*.j2` file below the template directories is parsed
at boot, so a vendored page (a Swagger UI `index.html`) or a templates directory that is really `public/` can stop the
boot, with the file name, path and line in the message. Name what to skip with globs on the path relative to a
template directory (`*` does not cross `/`, `**` does; `TEMPLATE_PRELOAD_IGNORE` splits on commas, so brace
alternation such as `{a,b}` cannot be written there, use the Crystal setter); the files are still found when asked for.
Dot directories and symlinked directories are not walked either, the file loader serves what is in them:

```crystal
require "azu"

Azu::CONFIG.template_preload_ignore = ["vendor/**", "swagger/*.html"] # or TEMPLATE_PRELOAD_IGNORE=vendor/**,swagger/*.html
```

A directory that cannot be read stops the boot with its name (`Azu.prepare`); a first render without `prepare` logs a
warning once and skips it, and because the names inside are unknown, a valid copy of one of them in a later directory
is served instead of falling back to the file loader's precedence. A name that does not parse in one directory is not
replaced by a copy in a later directory; `Azu.prepare` validates again even when a first render preloaded earlier.
A directory that does not exist is skipped (an API-only app costs nothing); a very broad one such as `.` is scanned
whole at boot, with the count and time logged at debug level.

## Request contracts

| Option | Type | Default |
|---|---|---|
| `error_format` | `Azu::ErrorFormat` | `Problem` |
| `format_parameter` | `String?` | `"format"` |

`Problem` answers every error a JSON client receives (a failed contract, a `404` from the router, `BadRequest`, a `500`, ...) with the same RFC 7807 problem body (`Content-Type: application/problem+json` only when the request's `Accept` names it, `application/json` otherwise); `Legacy` writes PascalCase bodies (`Status`, `Title`, `Detail`, ...) as `application/json` (see [Error types](../errors/error-types.md)).
`format_parameter` names the query parameter that picks the format of a `Response::Negotiable` (`?format=json`);
`nil` turns it off. A value that is not a format name (`html`, `json`, `xml`, `text`, `txt`) is ignored, so an
endpoint can have a `format` field of its own (see [Content negotiation](../api/content-negotiation.md)).
There is no `max_request_size` or `request_timeout` option; the size of uploaded files is limited below.

### Sessions

| Option | Type | Default |
|---|---|---|
| `session_adapter` | `Azu::SessionAdapter?` | `nil` |

How templates and the CSRF session token store reach your session library; see
[Session adapter](../api/session-adapter.md). `Azu.session_adapter=` sets it on the current configuration.

### Uploads

| Option | Type | Default | Environment |
|---|---|---|---|
| `upload.max_file_size` | `UInt64` | 10 MB | `UPLOAD_MAX_FILE_SIZE` (bytes) |
| `upload.max_request_size` | `UInt64` | 64 MB | `UPLOAD_MAX_REQUEST_SIZE` (bytes): the whole multipart request, counted as it streams in |
| `upload.max_parts` | `Int32` | 100 | `UPLOAD_MAX_PARTS`: fields and files of one multipart request |
| `upload.max_files` | `Int32` | 20 | `UPLOAD_MAX_FILES`: files of one multipart request |
| `upload.temp_dir` | `String` | `Dir.tempdir` | `UPLOAD_TEMP_DIR` |
| `upload.buffer_size` | `Int32` | 8192 | `UPLOAD_BUFFER_SIZE` |
| `upload.cleanup_interval` | `Time::Span` | 1 hour | `UPLOAD_CLEANUP_INTERVAL` (seconds) |
| `upload.max_temp_age` | `Time::Span` | 24 hours | `UPLOAD_MAX_TEMP_AGE` (seconds) |

`start` creates the temp directory and starts the task that deletes `azu_upload_*` files older than `max_temp_age`.

### WebSockets

| Option | Type | Default | Environment |
|---|---|---|---|
| `websocket.allowed_origins` | `Array(String)` | `[]` (own origin only) | `WEBSOCKET_ALLOWED_ORIGINS` (comma separated, `"*"` allows all) |
| `websocket.max_message_size` | `Int32` | 1 MB | `WEBSOCKET_MAX_MESSAGE_SIZE` |
| `websocket.ping_interval` | `Time::Span?` | 30 seconds | `WEBSOCKET_PING_INTERVAL` (seconds, `0` disables) |
| `websocket.tcp_nodelay` | `Bool` | `true` | `WEBSOCKET_TCP_NODELAY` (`false`, `0`, `off` or `no` in any case keeps the operating system's default; `true`, `1`, `on`, `yes` turn it on; anything else keeps the default and logs a warning) |

`websocket.tcp_nodelay` turns Nagle's algorithm off on the socket of an upgraded connection. A WebSocket reply
is often several small writes (a Spark event is answered by a diff, then a reply), and with Nagle on the
second waits for the peer's delayed ACK, about 40 ms per round trip on a Linux peer. Plain TCP sockets are set at
the upgrade, whatever server hosts the channel; the TLS listener `App#start` builds sets every connection it
accepts (the TCP socket under TLS is out of reach at the upgrade). Ordinary HTTP connections on a plain listener are
not touched. A server you bind to TLS yourself can use `Azu.bind_tls(server, host, port, context, reuse_port, true)`.

### Spark

Spark live views have their own `spark` section (`config.spark`, also `Azu::Spark.config`); its settings and the
`SPARK_*` variables are on [Spark configuration](spark.md).

### Cache

`cache` is the manager (`Azu.cache`), built on first use from `cache_config`, which is where you configure it.
Assigning a store (`config.cache = ...`) is not possible.

| Option | Type | Default | Environment |
|---|---|---|---|
| `cache_config.enabled?` | `Bool` | `true` | `CACHE_ENABLED` |
| `cache_config.store` | `String` | `"memory"` (`"redis"`, `"null"`) | `CACHE_STORE` |
| `cache_config.max_size` | `Int32` | 1000 | `CACHE_MAX_SIZE` |
| `cache_config.default_ttl` | `Int32` (seconds) | 3600 | `CACHE_DEFAULT_TTL` |
| `cache_config.key_prefix` | `String` | `"azu"` | `CACHE_KEY_PREFIX` |
| `cache_config.cache_cleanup_interval` | `Int32` (seconds) | 300 | `CACHE_CLEANUP_INTERVAL` |
| `cache_config.redis_url` | `String?` | `nil` (required for `store = "redis"`, unless `redis_client` is set) | `CACHE_REDIS_URL` |
| `cache_config.redis_pool_size` | `Int32` | 5 | `CACHE_REDIS_POOL_SIZE` |
| `cache_config.redis_timeout` | `Int32` (seconds) | 5 | `CACHE_REDIS_TIMEOUT` |
| `cache_config.redis_operation_timeout` | `Int32` (seconds) | 2 | `CACHE_REDIS_OPERATION_TIMEOUT` |
| `cache_config.redis_client` | `Azu::Redis::Client?` | `nil` | none (shares an existing client and pool) |
| `cache_config.cache_connection_retries` | `Int32` | 3 | `CACHE_CONNECTION_RETRIES` |
| `cache_config.cache_connection_retry_delay` | `Int32` (seconds) | 1 | `CACHE_CONNECTION_RETRY_DELAY` |

`compress?`, `serialize?` and the `file_cache_*` options exist and are read from `CACHE_COMPRESS`, `CACHE_SERIALIZE`,
`CACHE_FILE_PATH` and `CACHE_FILE_PERMISSIONS`, but nothing uses them yet. Settings changed after the first use of
`Azu.cache` do not rebuild the store. See the [cache reference](../api/cache.md).

```crystal
require "azu"

Azu::CONFIG.cache_config.store = "memory"
Azu::CONFIG.cache_config.max_size = 5_000
Azu::CONFIG.cache_config.default_ttl = 600
```

### i18n

| Option | Type | Default | Environment |
|---|---|---|---|
| `i18n.load_path` | `Array(String)` | `["locales"]` | `I18N_LOAD_PATH` (comma separated) |
| `i18n.default_locale` | `String` | `"en"` | `I18N_DEFAULT_LOCALE` |
| `i18n.available_locales` | `Array(String)` | `[]`: `Helpers::I18n` keeps its own list, `["en"]` | `I18N_AVAILABLE_LOCALES` (comma separated) |
| `i18n.fallback_locale` | `String?` | `nil` | `I18N_FALLBACK_LOCALE` |
| `i18n.raise_on_missing?` | `Bool` | `false` | `I18N_RAISE_ON_MISSING` |
| `i18n.missing_key_format` | `String` | `"[missing: %{key}]"` | `I18N_MISSING_KEY_FORMAT` |

Building an app's server (`App#start`, `App#server`, `Azu::Testing::Client`) applies the settings that differ from
these defaults to the process-wide `Helpers::I18n`; `load_path` only when one of its directories exists. The last app
to build a server wins. To change a setting at run time use the setters of `Azu::Helpers::I18n` (`default_locale=`,
`fallback_locale=`, ...).

### Assets

| Option | Type | Default | Environment |
|---|---|---|---|
| `assets.prefix` | `String` | `"/assets"` | `ASSETS_PREFIX` |
| `assets.path` | `String` | `"public/assets"` | `ASSETS_PATH` |
| `assets.fingerprint?` | `Bool` | `true` | `ASSETS_FINGERPRINT` |
| `assets.manifest_path` | `String` | `"public/assets/manifest.json"` | `ASSETS_MANIFEST_PATH` |
| `assets.cache_max_age` | `Int32` (seconds) | 31 536 000 | `ASSETS_CACHE_MAX_AGE` |
| `assets.integrity?` | `Bool` | `false` | `ASSETS_INTEGRITY` |

### Database

Only the instrumentation of `azu/cql` is configured here; the connection is CQL's.

| Option | Type | Default | Environment |
|---|---|---|---|
| `database.uri` | `String?` | `nil` | `DATABASE_URL` |
| `database.lazy_connect?` | `Bool` | `true` | `AZU_DB_LAZY` |
| `database.driver` | `String?` | `nil` (engine for `postgres://`) | `AZU_CQL_DRIVER` (`engine` or `db`) |
| `database.instrument?` | `Bool` | `true` | `AZU_DB_INSTRUMENT` |
| `database.n_plus_one_threshold` | `Int32` | 3 | `AZU_DB_N_PLUS_ONE_THRESHOLD` |
| `database.slow_query_ms` | `Float64` | 50.0 | `AZU_DB_SLOW_QUERY_MS` |
| `database.playground?` | `Bool` | `true` | `AZU_DB_PLAYGROUND` |
| `database.show_params?` | `Bool` | `false` | `AZU_DB_SHOW_PARAMS` (`"true"` enables) |

`database.show_params?` lets the dashboard show the bound values of each statement and database errors as the server
wrote them. It is honoured in development only (`show_database_params?` is `show_params? && env.development?`),
because values often hold personal data or secrets; turning it on also turns on `CQL::Telemetry.capture_params`.
See the [database dashboard](../database-dashboard.md).

### Performance tooling (`require "azu/dev"`)

These exist only after `require "azu/dev"`:

| Option | Type | Default | Environment |
|---|---|---|---|
| `performance_enabled?` | `Bool` | `false` | `PERFORMANCE_MONITORING` (`"true"` enables) |
| `performance_profiling_enabled` | `Bool?` | `nil`: on in `development` | `PERFORMANCE_PROFILING` (`"true"` enables, any other value disables) |
| `performance_memory_monitoring` | `Bool?` | `nil`: on in `development` | `PERFORMANCE_MEMORY_MONITORING` (`"true"` enables, any other value disables) |
| `performance_monitor` | `Handler::PerformanceMonitor?` | built on first read while `performance_enabled?` is on, else `nil` | none |

- `performance_enabled?` turns on request, cache and component metrics (`Handler::PerformanceMonitor` and the
  [instrumentation](../api/instrumentation.md) subscribers of `azu/dev`).
- `performance_profiling_enabled?` and `performance_memory_monitoring?` answer the setting, or whether the
  environment is `development` while it is `nil`. When `App#start` prepares the app they turn on the profiler and
  start the memory leak detector.
- `performance_monitor=` shares the monitor held by your handler chain, so the dashboard reads the same metrics.
- `development_tools` returns `Azu::DevelopmentTools` (the profiler and the memory leak detector).
- Building with `PERFORMANCE_MONITORING=true` (or `-Dperformance_monitoring`) makes `require "azu"` load `azu/dev`.

### Introspection

`handlers` holds the array given to `start`, for the development dashboard to draw. Assigning it does not change
what the server runs. `router` is the app's `Azu::Router`.

### Environment variables

Every variable Azu reads is in the tables on this page, plus the `REDIS_*` variables of
[`Azu::Redis::Config.from_env`](../api/redis.md#config) and the `PUBSUB_REDIS_URL` and `PRESENCE_REDIS_URL` of PubSub
and Presence. `REDIS_URL` is the fallback of `PUBSUB_REDIS_URL` and
`PRESENCE_REDIS_URL`, and deliberately not of `CACHE_REDIS_URL` (a Redis cache has no default URL). `AZU_ENV` and `SECRET_KEY` are not read: the signing secret of Spark
live views is `SPARK_SECRET`.

| Variable | Option |
|---|---|
| `CRYSTAL_ENV` | `env` |
| `PORT`, `HOST`, `PORT_REUSE`, `SHUTDOWN_TIMEOUT`, `KUBERNETES_SERVICE_HOST` | `port`, `host`, `port_reuse?`, `shutdown_timeout`, `container?` |
| `SSL_CERT`, `SSL_KEY`, `SSL_CA`, `SSL_MODE` | TLS |
| `TEMPLATE_HOT_RELOAD`, `TEMPLATE_AUTOESCAPE`, `TEMPLATE_PRELOAD_IGNORE`, `TEMPLATES_PATH`, `ERROR_TEMPLATE` | templates |
| `CACHE_*` | `cache_config` |
| `UPLOAD_*`, `WEBSOCKET_*`, `I18N_*`, `ASSETS_*`, `AZU_DB_*`, `AZU_CQL_DRIVER`, `DATABASE_URL` | the matching section |
| `SPARK_*` | [Spark configuration](spark.md) |
| `PERFORMANCE_MONITORING`, `PERFORMANCE_PROFILING`, `PERFORMANCE_MEMORY_MONITORING` | performance tooling (`azu/dev`) |

These are read outside `Azu::Configuration`:

| Variable | Type | Default | Meaning |
|---|---|---|---|
| `AZU_STRICT_ENVS` | comma separated environment names | `production` | Environments in which [`Azu::Env.secret`](env.md) raises `Azu::Env::MissingError` for an unset secret instead of using a random per-process value (`Azu::Env.strict_environments=` overrides it) |
| `CSRF_SECRET` | `String` | `Azu::Env.secret("CSRF_SECRET")`: random per process, `Azu::Env::MissingError` in the strict environments | Key `Handler::CSRF` signs its tokens with when it is given none |
| `PERFORMANCE_SLOW_REQUEST_THRESHOLD` | `Float64` (milliseconds) | `1000` | `Handler::PerformanceMonitor` (`azu/dev`) logs a warning for a request that takes longer |
| `PERFORMANCE_MEMORY_THRESHOLD` | `Int64` (bytes) | `10485760` (10 MB) | `Handler::PerformanceMonitor` (`azu/dev`) logs a warning for a request whose memory use grows by more |

### Per-environment configuration

Read the environment first, then adjust:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    case config.env
    when .production?
      config.template_hot_reload = false
      config.cache_config.store = "redis"
      config.cache_config.redis_url = ENV["CACHE_REDIS_URL"]
    when .test?
      config.port = 4001
    else
      config.template_hot_reload = true
    end
  end
end
```

## See also

- [Environments](environments.md)
- [Spark configuration](spark.md)
- [The Azu module](../api/app.md#the-azu-module)
- [Cache](../api/cache.md)

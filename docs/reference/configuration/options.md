# Configuration Options Reference

Every option of `Azu::Configuration`, with its type, default and environment variable. Defaults are read when the
configuration object is built, which for the global one happens when `azu` is required, so set environment
variables before that (or assign in code).

## Configuring Azu

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

## Server

| Option | Type | Default | Environment |
|---|---|---|---|
| `port` | `Int32` | `4000` | `PORT` |
| `host` | `String` | `"0.0.0.0"` | `HOST` |
| `port_reuse?` | `Bool` | `true` | `PORT_REUSE` (`"true"` enables) |
| `shutdown_timeout` | `Time::Span` | `30.seconds` | `SHUTDOWN_TIMEOUT` (seconds, never below 0) |

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

## Environment

`env` is an `Azu::Environment` (`Build`, `Development`, `Test`, `Integration`, `Acceptance`, `Pipeline`, `Staging`,
`Production`), read from `CRYSTAL_ENV` (case-insensitive) and `Development` when unset. An unknown value raises
`ArgumentError: Unknown enum Azu::Environment value` when the configuration is built. `AZU_ENV` is not read.
What each environment changes is on the [environments page](environments.md).

```crystal
require "azu"

Azu::CONFIG.env = Azu::Environment::Production
puts Azu::CONFIG.env.production?
```

## Logging

| Option | Type | Default |
|---|---|---|
| `log` | `Log` | `Log.for("Azu")` |

`log` is the logger the framework writes to (request lines of `Handler::Logger`, cache and upload messages). The
level and the backend belong to Crystal's `Log`: there is no `log.level` or `log.backend` option. Set them with
`Log.setup`, or call `Azu.setup_logging` for Azu's format at `Debug`. See
[How to Add Logging](../../how-to/middleware/add-logging.md).

```crystal
require "azu"

Azu::CONFIG.log = Log.for("my_app")
```

## Templates

| Option | Type | Default | Environment |
|---|---|---|---|
| `template_hot_reload?` | `Bool` | `true` for `development`, `test` and `pipeline`, else `false` | `TEMPLATE_HOT_RELOAD` |
| `templates.path` | `Array(String)` | the working directory's `../../templates` | `TEMPLATES_PATH` (comma separated) |
| `templates.error_path` | `String` | Azu's own error templates | `ERROR_TEMPLATE` |

The default template path is a leftover that resolves relative to the working directory, so set `TEMPLATES_PATH`
or add your directory. `templates.path = "..."` **adds** a directory to the list:

```crystal
require "azu"

Azu::CONFIG.templates.path = "./public/templates"
Azu::CONFIG.template_hot_reload = false
```

With hot reload on, `templates` re-reads template files that changed (it checks at most once a second). Hot reload
off does not mean templates are cached: a template whose file was rewritten rendered the new content with it off
as well.

## Request Contracts

| Option | Type | Default |
|---|---|---|
| `error_format` | `Azu::ErrorFormat` | `Problem` |

`Problem` answers a failed contract with RFC 7807 `application/problem+json`; `Legacy` keeps the pre-0.6 body.
There is no `max_request_size` or `request_timeout` option; the size of uploaded files is limited below.

## Uploads

| Option | Type | Default | Environment |
|---|---|---|---|
| `upload.max_file_size` | `UInt64` | 10 MB | `UPLOAD_MAX_FILE_SIZE` (bytes) |
| `upload.temp_dir` | `String` | `Dir.tempdir` | `UPLOAD_TEMP_DIR` |
| `upload.buffer_size` | `Int32` | 8192 | `UPLOAD_BUFFER_SIZE` |
| `upload.cleanup_interval` | `Time::Span` | 1 hour | `UPLOAD_CLEANUP_INTERVAL` (seconds) |
| `upload.max_temp_age` | `Time::Span` | 24 hours | `UPLOAD_MAX_TEMP_AGE` (seconds) |

`start` creates the temp directory and starts the task that deletes `azu_upload_*` files older than `max_temp_age`.

## WebSockets

| Option | Type | Default | Environment |
|---|---|---|---|
| `websocket.allowed_origins` | `Array(String)` | `[]` (own origin only) | `WEBSOCKET_ALLOWED_ORIGINS` (comma separated, `"*"` allows all) |
| `websocket.max_message_size` | `Int32` | 1 MB | `WEBSOCKET_MAX_MESSAGE_SIZE` |
| `websocket.ping_interval` | `Time::Span?` | 30 seconds | `WEBSOCKET_PING_INTERVAL` (seconds, `0` disables) |
| `websocket.tcp_nodelay` | `Bool` | `true` | `WEBSOCKET_TCP_NODELAY` (`false` keeps the operating system's default) |

`websocket.tcp_nodelay` turns Nagle's algorithm off on the socket of an upgraded connection. A WebSocket reply
is often several small writes (a Spark event is answered by a diff, then a reply), and with Nagle on the
second waits for the peer's delayed ACK, about 40 ms per round trip on a Linux peer. Plain TCP sockets are set at
the upgrade, whatever server hosts the channel; the TLS listener `Azu.start` builds sets every connection it
accepts (the TCP socket under TLS is out of reach at the upgrade). Ordinary HTTP connections on a plain listener are
not touched. A server you bind to TLS yourself can use `Azu.bind_tls(server, host, port, context, reuse_port, true)`.

Spark live views have their own `spark` section (`SPARK_*` variables, `Azu::Spark.configure`), described in
[Spark live views](../../explanation/spark-live-views.md).

## Cache

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
| `cache_config.redis_url` | `String` | `"redis://localhost:6379/0"` | `CACHE_REDIS_URL` |
| `cache_config.redis_pool_size` | `Int32` | 5 | `CACHE_REDIS_POOL_SIZE` |
| `cache_config.redis_timeout` | `Int32` (seconds) | 5 | `CACHE_REDIS_TIMEOUT` |
| `cache_config.redis_operation_timeout` | `Int32` (seconds) | 2 | `CACHE_REDIS_OPERATION_TIMEOUT` |
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

## i18n

| Option | Type | Default | Environment |
|---|---|---|---|
| `i18n.load_path` | `Array(String)` | `["locales"]` | `I18N_LOAD_PATH` (comma separated) |
| `i18n.default_locale` | `String` | `"en"` | `I18N_DEFAULT_LOCALE` |
| `i18n.available_locales` | `Array(String)` | detected from files | `I18N_AVAILABLE_LOCALES` |
| `i18n.fallback_locale` | `String?` | `nil` | `I18N_FALLBACK_LOCALE` |
| `i18n.raise_on_missing?` | `Bool` | `false` | `I18N_RAISE_ON_MISSING` |
| `i18n.missing_key_format` | `String` | `"[missing: %{key}]"` | `I18N_MISSING_KEY_FORMAT` |

The settings are applied to the process-wide `Helpers::I18n` when the configuration is built (and only when one of
the load paths exists), so to change them later use the setters of `Azu::Helpers::I18n` (`default_locale=`, `fallback_locale=`, ...).

## Assets

| Option | Type | Default | Environment |
|---|---|---|---|
| `assets.prefix` | `String` | `"/assets"` | `ASSETS_PREFIX` |
| `assets.path` | `String` | `"public/assets"` | `ASSETS_PATH` |
| `assets.fingerprint?` | `Bool` | `true` | `ASSETS_FINGERPRINT` |
| `assets.manifest_path` | `String` | `"public/assets/manifest.json"` | `ASSETS_MANIFEST_PATH` |
| `assets.cache_max_age` | `Int32` (seconds) | 31 536 000 | `ASSETS_CACHE_MAX_AGE` |
| `assets.integrity?` | `Bool` | `false` | `ASSETS_INTEGRITY` |

## Database

Only the instrumentation of `azu/cql` is configured here; the connection is CQL's.

| Option | Type | Default | Environment |
|---|---|---|---|
| `database.uri` | `String?` | `nil` | `DATABASE_URL` |
| `database.lazy_connect?` | `Bool` | `true` | `AZU_DB_LAZY` |
| `database.instrument?` | `Bool` | `true` | `AZU_DB_INSTRUMENT` |
| `database.n_plus_one_threshold` | `Int32` | 3 | `AZU_DB_N_PLUS_ONE_THRESHOLD` |
| `database.slow_query_ms` | `Float64` | 50.0 | `AZU_DB_SLOW_QUERY_MS` |
| `database.playground?` | `Bool` | `true` | `AZU_DB_PLAYGROUND` |

See the [database dashboard](../database-dashboard.md).

## Performance Tooling (`require "azu/dev"`)

After `require "azu/dev"`, `Configuration` also has `performance_enabled?` (`PERFORMANCE_MONITORING=true`),
`performance_profiling_enabled?` (`PERFORMANCE_PROFILING`) and `performance_memory_monitoring?`
(`PERFORMANCE_MEMORY_MONITORING`); the last two default to on in `Development`. Without the require these
methods do not exist.

## Introspection

`handlers` holds the array given to `start`, for the development dashboard to draw. Assigning it does not change
what the server runs. `router` is the app's `Azu::Router`.

## Environment Variables

Every variable Azu reads is in the tables above. `AZU_ENV`, `REDIS_URL` and `SECRET_KEY` are not read: the Redis
URL is `CACHE_REDIS_URL`, and the signing secret of Spark live views is `SPARK_SECRET`.

| Variable | Option |
|---|---|
| `CRYSTAL_ENV` | `env` |
| `PORT`, `HOST`, `PORT_REUSE`, `SHUTDOWN_TIMEOUT` | `port`, `host`, `port_reuse?`, `shutdown_timeout` |
| `SSL_CERT`, `SSL_KEY`, `SSL_CA`, `SSL_MODE` | TLS |
| `TEMPLATE_HOT_RELOAD`, `TEMPLATES_PATH`, `ERROR_TEMPLATE` | templates |
| `CACHE_*` | `cache_config` |
| `UPLOAD_*`, `WEBSOCKET_*`, `I18N_*`, `ASSETS_*`, `AZU_DB_*`, `DATABASE_URL`, `SPARK_*` | the matching section |

## Per-Environment Configuration

Read the environment first, then adjust:

```crystal
require "azu"

module MyApp
  include Azu

  configure do |config|
    config.port = ENV.fetch("PORT", "4000").to_i

    case config.env
    when .production?
      config.template_hot_reload = false
      config.cache_config.store = "redis"
      config.cache_config.redis_url = ENV.fetch("CACHE_REDIS_URL", "redis://localhost:6379/0")
    when .test?
      config.port = 4001
    else
      config.template_hot_reload = true
    end
  end
end
```

## See Also

- [Environments Reference](environments.md)
- [Core Reference](../api/core.md)
- [Cache Reference](../api/cache.md)

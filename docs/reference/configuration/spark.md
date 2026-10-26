---
description: "Every setting of Spark live views: its type, default, environment variable and meaning, and the signing secret rule."
---

# Spark configuration

`Azu::Spark::Configuration` holds the settings of Spark live views: where the WebSocket and the client script are
served, how long tokens live, and the limits a connection works within. Each configuration has one,
`config.spark`, so the global one is `Azu::CONFIG.spark`; it comes with `require "azu"`. Every setting reads a
`SPARK_*` environment variable when the configuration is built, which for `Azu::CONFIG` happens when `azu` is
required. The components themselves are on [Component](../api/component.md).

```crystal
require "azu"

Azu::Spark.configure do |spark|
  spark.allowed_origins = ["https://app.example.com"]
  spark.token_ttl = 2.hours
end

Azu::Spark.install
```

## Options

| Option | Type | Default | Environment | Meaning |
|---|---|---|---|---|
| `secret` | `String` | see [The secret](#the-secret) | `SPARK_SECRET` | Key that signs join tokens and state snapshots |
| `path` | `String` | `"/spark"` | `SPARK_PATH` | URL the WebSocket is served from |
| `assets_path` | `String` | `"/_spark/azu_spark.js"` | `SPARK_ASSETS_PATH` | URL the client script is served from |
| `token_ttl` | `Time::Span` | 24 hours | `SPARK_TOKEN_TTL` (seconds) | How long a rendered page may wait before it joins |
| `allowed_origins` | `Array(String)` | `[]` (own origin only) | `SPARK_ALLOWED_ORIGINS` (comma separated, `"*"` accepts any) | Origins accepted besides the page's own, in addition to `websocket.allowed_origins` |
| `max_message_size` | `Int32` | 65536 | `SPARK_MAX_MESSAGE_SIZE` (bytes) | Largest client frame accepted |
| `compress_threshold` | `Int32` | 1024 | `SPARK_COMPRESS_THRESHOLD` (bytes, `0` turns it off) | Smallest diff frame sent gzipped to a client that announced `gzip` |
| `max_components` | `Int32` | 200 | `SPARK_MAX_COMPONENTS` | Components (roots and children) one connection may own |
| `events_per_second` | `Float64` | 30.0 | `SPARK_EVENTS_PER_SECOND` | Sustained events per second a connection may send |
| `event_burst` | `Int32` | 60 | `SPARK_EVENT_BURST` | Events a connection may send at once |
| `heartbeat_interval` | `Time::Span` | 20 seconds | `SPARK_HEARTBEAT_INTERVAL` (seconds) | Time between client heartbeats, sent to the client when it connects |
| `idle_timeout` | `Time::Span` | 60 seconds | `SPARK_IDLE_TIMEOUT` (seconds) | A connection silent this long is closed |
| `snapshot_ttl` | `Time::Span` | 1 hour | `SPARK_SNAPSHOT_TTL` (seconds) | How long a state snapshot may wait for its reconnect |
| `max_snapshot_size` | `Int32` | 4096 | `SPARK_MAX_SNAPSHOT_SIZE` (bytes) | Largest signed state snapshot handed to the client |

`snapshot_ttl` is shorter than `token_ttl` on purpose: persisted state can be read and replayed by the browser until
it expires.

## API

| Method | Returns | Notes |
| --- | --- | --- |
| `Azu::Spark.config` | `Spark::Configuration` | `Azu.current_config.spark`: inside a request, the settings of the app serving it |
| `Azu::Spark.configure(& : Spark::Configuration ->)` | `Nil` | Yields `Spark.config` |
| `Spark::Configuration#verify!` | `Nil` | Raises `Azu::Spark::ConfigurationError` when the environment needs a secret and none is set; `Spark.install` calls it |

## Behavior

### The secret

`secret` is the value assigned in code (`spark.secret = ...`), else `SPARK_SECRET` (an empty value counts as unset).
Without either:

| Environment | `secret` |
|---|---|
| `production`, `staging` | raises `Azu::Spark::ConfigurationError`, and so does `Azu::Spark.install`, at boot and before it registers a route |
| every other | a random value (64 hex characters), generated once per configuration, so tokens and snapshots do not survive a restart and are not accepted by another process |

The environment is that of the current configuration (`Azu.current_config.env`). Every process that serves the same
pages needs the same secret: set `SPARK_SECRET` to the same value on every node.

### Other rules

- The `Time::Span` and integer settings are parsed with `to_i` (`to_f` for `events_per_second`): a value that is not
  a number raises `ArgumentError` when the configuration is built.
- The settings are read where they are used, so set them before `Azu::Spark.install` (which registers `path` and
  `assets_path` on the router) and before the first connection.

## See also

- [Component](../api/component.md)
- [Spark JavaScript client](../spark-client.md)
- [Spark live views](../../explanation/spark-live-views.md)
- [Configuration options](options.md)

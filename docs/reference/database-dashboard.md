---
description: How the dev dashboard's Database tab records every SQL statement an Azu app runs, how to set it up with CQL, and how another ORM can feed it.
---

# Database dashboard

The dev dashboard's **Database** tab shows the SQL statements an app runs: KPIs, N+1 analysis, recent queries tagged
with the request that ran them, slow queries, query patterns, transactions, connection pool usage and a read-only SQL
playground. The dashboard comes with `require "azu/dev"`; the statements come from an integration that records into
`Azu::QueryStore`. For CQL that is `require "azu/cql"`, which subscribes to CQL's events and does not wrap or patch
CQL; another ORM can record into the same store. Azu core does not depend on CQL. The tab is not a production query
log: the store records in every environment, but the dashboard and its SQL playground serve in development only.

The CQL setup lives in one initializer of your app, which configures CQL with its own `configure` and attaches the
dashboard:

```crystal
# src/initializers/cql_config.cr
require "sqlite3"      # not needed for PostgreSQL (CQL's native engine); mysql for MySQL; add `cql` to your shard.yml
require "azu/cql"

Azu::CQL.configure do |c|            # forwards to CQL.configure
  c.db = ENV["DATABASE_URL"]
  c.pool.size = 10
end

Azu::CQL.attach { AppDB }            # the dashboard resolves AppDB the first time it needs it

# src/db/schema.cr
AppDB = Azu::CQL.schema :app do      # URL, adapter and pool come from CQL.config
  table :users do
    primary :id, Int64
    column :name, String
  end
end

# src/models/user.cr
class User
  include ::CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  property name : String

  def initialize(@name : String)
  end
end

User.where(name: "Ada").all
```

That is the whole setup (three files, shown here as one block). Models, queries, transactions and migrations are plain
CQL, and every query shows up in the dashboard tagged with the request that ran it. A runnable PostgreSQL example laid
out like this is [`playground/azu_cql_postgres`](https://github.com/azutoolkit/azu/blob/master/playground/azu_cql_postgres/app.cr).

## API

### `Azu::CQL`

| Method | Returns | Notes |
| --- | --- | --- |
| `configure { \|c\| ... }` | `::CQL::Configure::Config` | Installs the instrumentation, then forwards to `CQL.configure` |
| `schema(name = :app, uri = nil, lazy = nil, driver = nil) { ... }` | `::CQL::Schema` | Defines a schema, installs the instrumentation and attaches it; see [Schema connections](#schema-connections) |
| `attach(schema)` | `::CQL::Schema` | Attaches an existing schema: the pool card and the SQL playground use it |
| `attach { AppDB }` | `Nil` | The same for a schema defined later; the block runs the first time the dashboard needs it |
| `verify!(schema)` | `::CQL::Schema` | Runs `SELECT 1`; raises `Azu::CQL::VerificationError` naming the redacted URL when the database cannot be reached |
| `health_check(schema, timeout = 2.seconds)` | `Proc(Bool)` | A check for `Azu::Handler::HealthCheck` |
| `engine(schema)` | `::CQL::Postgres::AsyncEngine?` | The native PostgreSQL engine behind a schema, `nil` on crystal-db's pool |
| `transaction(schema) { ... }` | | Runs the block in `schema.transaction`; its statements show as one transaction in the tab |
| `request_cache_stats` | `Azu::CQL::RequestCacheStats?` | The current request's counts from CQL's request cache (`queries`, `repeated`), with `Middleware.new(query_cache: true)`; see [CQL bridge](api/cql-bridge.md#azucqlmiddleware) |
| `track(schema)`, `untrack(schema)`, `shutdown` | `Nil` | The schemas whose pools `Azu.shutdown` closes (`schema` and `attach` track for you) |
| `Instrumentor.install`, `Instrumentor.uninstall`, `Instrumentor.installed?` | | The `CQL::Telemetry` subscribers (named `azu.dashboard`); installing twice replaces them |

CQL's types are also reachable under the Azu namespace (`Azu::CQL::Schema`, `Azu::CQL::ActiveRecord::Model`, ...), so
an app that does `include Azu` never has to name `::CQL`, and `CQL.configure` inside such a namespace is
`Azu::CQL.configure`. Request and response mapping and `Azu::CQL::Middleware` are on [CQL bridge](api/cql-bridge.md).

### `Azu::QueryStore`

`Azu::QueryStore.instance` is the process-wide store the tab reads. It is thread-safe and keeps the last 2,000 queries
(`MAX_QUERIES`) and 200 transactions (`MAX_TRANSACTIONS`).

| Member | Returns | Notes |
| --- | --- | --- |
| `enabled?`, `enabled=` | `Bool` | The tab reads the store only while this is true; `Azu::CQL::Instrumentor.install` sets it |
| `adapter`, `adapter=` | `DatabaseAdapter?` | What the pool card and the SQL playground use |
| `record_query(sql, params, duration_ms, rows, error, caller_location, transaction_id, request_id, endpoint, method, path, fiber_id, operation = nil, pool_wait_ms = 0.0, context = nil, adapter = nil, params_shown = false)` | `QueryMetric` | Records one statement; logs it when it is slow (see [Slow queries](#slow-queries)) |
| `record_transaction_begin(id, nested, request_id, endpoint)`, `record_transaction_end(id, committed, duration_ms, error = nil)` | `Nil` | A statement recorded with that `transaction_id` in between counts toward the transaction |
| `queries(since = 0, limit = 500)` | `Array(QueryMetric)` | Statements with an id above `since`, oldest first |
| `transactions(limit = 50)` | `Array(TransactionMetric)` | Newest first |
| `n_plus_one(threshold = 3)` | `Array(NPlusOneAlert)` | See [N+1 detection](#n1-detection) |
| `pool` | `PoolSnapshot?` | From `pool_provider=` when one is set, else from the adapter |
| `pool_provider=(provider : Proc(PoolSnapshot?)?)` | | Pool figures without an adapter |
| `last_id`, `clear` | | |

`Azu::RequestContext.current?` gives the request the current fiber serves (`request_id`, `method`, `path`,
`endpoint`), which `Handler::RequestId` and the endpoint set; `Azu::QueryAnalysis.safe_error(exception)` gives the
redacted error text described below.

### `Azu::DatabaseAdapter`

The abstract class an integration subclasses for the pool card and the SQL playground:

| Method | Returns | Notes |
| --- | --- | --- |
| `read_only(sql : String, limit : Int32)` | `{Array(String), Array(Array(String?))}` | Runs the statement, which the playground has already checked, in a transaction that is always rolled back; at most `limit` rows, values as text, `nil` for NULL |
| `pool` | `PoolSnapshot?` | `PoolSnapshot.new(open, idle, in_flight, max)` |
| `dialect` | `String` | Picks the EXPLAIN syntax: `"sqlite"`, `"postgres"`, anything else gets plain `EXPLAIN` |
| `adapter_name`, `connection_source` | `String?` | Optional; shown on the pool card |

## Options

Set them in your app's `configure` block, or with the environment variable:

| Option | Type | Default | Environment | Meaning |
| --- | --- | --- | --- | --- |
| `database.instrument?` | `Bool` | `true` | `AZU_DB_INSTRUMENT` | Record CQL's events into the store |
| `database.n_plus_one_threshold` | `Int32` | `3` | `AZU_DB_N_PLUS_ONE_THRESHOLD` | Repetitions of one statement shape in one request that make an N+1 alert |
| `database.slow_query_ms` | `Float64` | `50.0` | `AZU_DB_SLOW_QUERY_MS` | Statements this slow are flagged and logged; `0` turns the log off |
| `database.show_params?` | `Bool` | `false` | `AZU_DB_SHOW_PARAMS` | Show bound values and unredacted errors, in development only (see below) |
| `database.playground?` | `Bool` | `true` | `AZU_DB_PLAYGROUND` | Offer the SQL playground |
| `database.lazy_connect?` | `Bool` | `true` | `AZU_DB_LAZY` | `Azu::CQL.schema` connects on the first query |
| `database.driver` | `String?` | `nil` | `AZU_CQL_DRIVER` | `engine` or `db`, see [Schema connections](#schema-connections) |
| `database.uri` | `String?` | `nil` | `DATABASE_URL` | Deprecated fallback URL of `Azu::CQL.schema`; use `CQL.configure { \|c\| c.db = ... }` |

## Behavior

### How the tab is fed

| Piece | Where | Role |
| --- | --- | --- |
| `CQL::Telemetry` | cql `src/telemetry.cr` | Query and transaction events; costs nothing without subscribers |
| `Azu::CQL::Instrumentor` | `src/azu/cql/instrumentor.cr` | Subscribes (as `azu.dashboard`) and records the events in `Azu::QueryStore` |
| `Azu::RequestContext` | `src/azu/request_context.cr` | The current request, keyed by fiber; set by `Handler::RequestId` and `Endpoint#call` |
| `Azu::QueryStore` | `src/azu/query_store.cr` | The bounded store, N+1 analysis, transactions, pool snapshot, error redaction |
| `Dashboard::DatabaseData` | `src/azu/dev/dev_dashboard/database_data.cr` | The tab's numbers: from `QueryStore` while it is enabled, else from CQL's own monitor |
| `Dashboard::DatabaseSection` | `src/azu/dev/dev_dashboard/database_section.cr` | The cards (queries, transactions, pool, playground) |
| `Handler::DevDashboard` | `src/azu/dev/dev_dashboard.cr` | Serves the page and `POST {path}/sql`, in development only |

The subscribers are synchronous on purpose: an `async: true` subscriber runs on another fiber, where the request, the
call site and the open transaction are no longer visible. Without `azu/cql` the tab falls back to CQL's own performance
monitor (when `cql` is required before `azu`), or shows an "n/a" card that says how to install the bridge. While the
store is enabled, its statements take precedence. While the database is down the tab still renders: the pool card shows
no open connections and the SQL playground reports the connection error.

### What the tab shows of your data

Bound values often hold passwords and personal data, so the tab keeps them out by default. What that does and does not cover:

* **Bound values** (`where(name: x)`, `insert.values(...)`) show as `?` placeholders, even when your app turned on
  `CQL::Telemetry.capture_params` for its own tracing.
* **Error text** shows the exception class, its SQLSTATE when the exception has one, and a short text only for messages the
  dashboard recognises from their whole first line, such as `relation "users" does not exist`,
  `duplicate key value violates unique constraint "name"`, `UNIQUE constraint failed: users.email`, `no such table: users`,
  `column "c" of relation "t" does not exist`, `CHECK constraint failed: name`, `Table 'db.users' doesn't exist`,
  `Unknown column 'x' in 'field list'`, `syntax error` (without the token) and MySQL's
  `Duplicate entry for key 'name'` (without the value). The text is rebuilt from the identifiers the message names, and only a plain
  identifier (`[\w.$]{1,128}`) is accepted as one. Every other error, including every message that quotes a value, shows the class and code
  alone. An identifier is at most 128 characters, and a `UNIQUE constraint failed` list names at most 32 columns. A value the server treats
  as an identifier is shown when it looks like one: a PostgreSQL `::regclass`, `nextval($1)` or `to_regclass($1)` cast of a bound value
  fails with `relation "<value>" does not exist`, and the value appears in that text. Recognition is English-only: a localized server
  shows the class and code. The SQL playground's 422 answer follows the same rule.
* **Hand-written SQL is shown as written.** A literal you put into a `schema.exec` string, or build by interpolation, is part of the
  statement text and appears in Recent queries, Slow queries, Query patterns (the pattern view replaces literals with `?`) and
  in the slow-query log line. Bind values instead of interpolating them.
* **Opt-in.** `database.show_params` (`AZU_DB_SHOW_PARAMS=true`) shows the bound values (long ones cut at 200 characters, binary as
  `<n bytes>`) and the server's error text unredacted. It is honoured in development only. It turns on `CQL::Telemetry.capture_params`
  for the whole process while the instrumentor is installed, so every other telemetry subscriber (your tracing, logging) receives the
  values as well; `Instrumentor.uninstall` puts the previous setting back.
* A rollback on purpose (`DB::Rollback`, or an exception that includes `Azu::CQL::Instrumentor::IntentionalRollback`, which is
  what `Azu::CQL::Middleware` raises for a 4xx) is shown as "rolled back" without an error.
* The page escapes every value it renders (SQL, errors, tags, endpoint names).

### Slow queries

A statement at or over `database.slow_query_ms` is counted on the Slow queries card and logged once at warn level, in
every environment, with up to 300 characters of its SQL:

```text
2026-10-26T15:11:34.843183Z   WARN - Azu: Slow query (447.0ms, limit 50.0ms) in SlowEndpoint: WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1500000) SELECT count(*) FROM c
```

Slow statements are judged by `database.slow_query_ms`, not by `CQL::Telemetry.alert_on_slow`, so the tab and the log agree.

### N+1 detection

Within one request, a `SELECT` whose normalized shape (literals and bindings replaced by `?`, `IN` lists collapsed) runs
at least `n_plus_one_threshold` times is reported with its count, total time, call site and an eager-load hint. A
statement counts as a `SELECT` by CQL's own `operation` label, so a CTE or a `UNION` built with CQL counts too; raw
`schema.exec` is classified by its first keyword. An alert whose count is three times the threshold or more is
critical, the others high.

### SQL playground

The card appears when the environment is development, an adapter is attached (`Azu::CQL.schema` or `attach`) and
`database.playground?` is on. The browser posts `{"sql": "...", "mode": "run"}` to `{path}/sql` (`mode` is `run`,
`explain` or `explain_analyze`) and gets the columns and rows back:

```json
{"columns":["n"],"rows":[["6"]],"duration_ms":0.173324,"truncated":false}
```

| Request | Answer |
| --- | --- |
| No adapter, playground off, or a client that is not on a loopback address | `404` `{"error":"SQL playground is not available"}` |
| Any method but `POST` | `405` `{"error":"POST required"}` |
| No `X-Requested-With: azu-dashboard` header, or an `Origin` other than the `Host` | `403` `{"error":"Cross-origin request refused"}` |
| A body that is not JSON (only the first 10,000 bytes are read) | `400` `{"error":"Invalid JSON body"}` |
| Anything but one `SELECT`, `WITH` or `EXPLAIN` statement: a write, a second statement, a comment | `400` `{"error":"Only a single read-only SELECT / WITH / EXPLAIN statement is allowed (EXPLAIN works on SELECT / WITH)."}` |
| A statement that fails | `422` with the redacted error, such as `{"error":"SQLite3::Exception: no such table: nope"}` |
| Otherwise | `200`, at most 200 rows; `truncated` is true when there were more |

Outside development the dashboard passes `{path}/sql` on like any other request, so the app answers it (a `404` when
nothing is routed there). The statement runs in a transaction that is always rolled back. `explain` wraps a `SELECT` or `WITH` in `EXPLAIN QUERY
PLAN` on SQLite and `EXPLAIN` elsewhere; `explain_analyze` is `EXPLAIN (ANALYZE, BUFFERS)` on PostgreSQL, which runs the
statement. `{path}/sql` is exempt from CSRF checks.

### Schema connections

* **Why `attach { }`?** Initializers load before `db/schema.cr`, and a schema file regenerated by CQL's dump is a plain
  `CQL::Schema.define`. The block is only evaluated when the dashboard needs the schema, so it works with either form.
  A one-file app can define the schema in the initializer instead: `AppDB = Azu::CQL.schema :app { ... }` (it attaches itself).
  An existing schema can be attached directly: `Azu::CQL.attach(AppDB)`.
* **Which URL?** In order: the `uri` argument of `Azu::CQL.schema`, `CQL.config.db` once it has been set, then
  `database.uri`. With none of them `Azu::CQL.schema` raises. The adapter comes from the scheme (`postgres://`,
  `postgresql://`, `mysql://`, `sqlite3://`; anything else raises).
* **Pool settings.** When the URL comes from `CQL.config`, `c.pool.size`, `c.pool.max_idle_size` and `c.pool.checkout_timeout`
  are appended to it as crystal-db parameters (`max_pool_size`, ...). Parameters already in the URL always win.
  Azu does not use `CQL.config.full_db_url`, which also injects SSL, authentication and retry settings:
  put `?sslmode=require` in the URL yourself.
* **SQLite defaults.** For a `sqlite3://` URL taken from `CQL.config`, the `c.sqlite` settings (`journal_mode` WAL,
  `foreign_keys` on, `busy_timeout` 5000, `synchronous`, `cache_size`) are appended the same way, so the schema opens
  connections the way `CQL.build_schema` does. An explicit `uri` argument is used as given.
  Rows or fixtures that violate a foreign key fail with `FOREIGN KEY constraint failed`. Opt out with
  `CQL.configure { |c| c.sqlite.foreign_keys = false }` (or `busy_timeout`, `journal_mode`, ...), or per URL with
  `?foreign_keys=0`; parameters on the URL always win.
* **Lazy connection.** The schema is created without opening a socket (`initial_pool_size=0`), so the app, console and
  tasks boot without a database and the first query connects. Turn it off with `config.database.lazy_connect = false`
  in your app's `configure` block, before the schema is defined (`AZU_DB_LAZY=false`), per schema with
  `Azu::CQL.schema(:app, lazy: false)`, or with `initial_pool_size` in the URL. To fail fast (for example at boot in
  production) call `Azu::CQL.verify!(AppDB)`.
* **PostgreSQL runs on CQL's native engine by default.** For `postgres://` and `postgresql://` URLs the schema is built
  on `CQL::Postgres::EngineSource` (a `CQL::Postgres::AsyncEngine` pool: fiber-safe, prepared-statement cache, binary
  results, health-checked connections), so models, queries, `Model.transaction` and migrations use it and the `pg` shard is
  not needed. SQLite and MySQL use crystal-db; `cockroachdb://` stays on crystal-db unless you ask for `driver: :engine`.
  Opt out with `Azu::CQL.schema(:app, driver: :db)` or `AZU_CQL_DRIVER=db` (crystal-db's pool and whichever driver is
  registered; with `require "pg"` that is the `pg` shard). The argument wins over the variable. Pool settings from
  `CQL.config.pool` map to the engine's URL parameters: `pool.size` or `max_pool_size` become `pool_size`, an eager connection
  (`lazy: false`) opens `pool_min_size = min(pool.initial_size, pool_size)` connections, `checkout_timeout` keeps its name,
  `pool.use_prepared_statements = false` and `prepared_statements=false` become `statement_cache_size=0`.
  `max_idle_pool_size`, `retry_attempts`, `retry_delay` and `auth_methods` are dropped (the engine does not retry
  connects). Parameters on the URL always win, and engine-only ones (`sslmode`, `max_queries`, `max_idle_lifetime`,
  `statement_cache_size`, `binary_params`, ...) pass through. Behind PgBouncer in transaction mode add
  `statement_cache_size=0`. `Azu.shutdown` closes the pools after PubSub, before Redis.
* **Health check.** `Azu::Handler::HealthCheck.new(checks: {"database" => Azu::CQL.health_check(AppDB, 2.seconds)})` runs `SELECT 1` and is
  false when it fails or takes longer than the timeout. It answers "is the database up": when every pooled connection of an
  engine schema is busy it uses one extra connection (a full handshake, so check every few seconds, not every request) instead
  of queueing behind the pool. A probe still running (a hung database) is not stacked; the next check is false until it ends,
  bounded by `checkout_timeout` and `connect_timeout`.

### Feeding the tab from another ORM

An ORM without CQL's events records into the store itself, from the fiber that ran the statement, and gives the pool
card and the SQL playground a `DatabaseAdapter`. With crystal-db:

```crystal
require "azu"
require "db"
require "sqlite3"

class CrystalDbAdapter < Azu::DatabaseAdapter
  def initialize(@db : DB::Database, @dialect : String)
  end

  def read_only(sql : String, limit : Int32) : {Array(String), Array(Array(String?))}
    columns = [] of String
    rows = [] of Array(String?)
    @db.transaction do |tx|
      tx.connection.query(sql) do |result|
        columns = result.column_names
        while rows.size < limit && result.move_next
          rows << Array(String?).new(columns.size) { result.read.try(&.to_s) }
        end
      end
      tx.rollback
    end
    {columns, rows}
  end

  def pool : Azu::PoolSnapshot?
    stats = @db.pool.stats
    Azu::PoolSnapshot.new(stats.open_connections, stats.idle_connections, stats.in_flight_connections, stats.max_connections)
  end

  def dialect : String
    @dialect
  end
end

def record_statement(sql : String, elapsed : Time::Span, rows : Int64?, error : Exception?) : Nil
  request = Azu::RequestContext.current?
  Azu::QueryStore.instance.record_query(
    sql: sql, params: [] of String, duration_ms: elapsed.total_milliseconds, rows: rows,
    error: error.try { |ex| Azu::QueryAnalysis.safe_error(ex) }, caller_location: nil, transaction_id: nil,
    request_id: request.try(&.request_id), endpoint: request.try(&.endpoint), method: request.try(&.method),
    path: request.try(&.path), fiber_id: Fiber.current.object_id)
end

db = DB.open("sqlite3://./app.db")
store = Azu::QueryStore.instance
store.adapter = CrystalDbAdapter.new(db, "sqlite")
store.enabled = true # the tab reads the store from now on

started = Time.instant
result = db.exec("CREATE TABLE IF NOT EXISTS notes (body TEXT)")
record_statement("CREATE TABLE IF NOT EXISTS notes (body TEXT)", Time.instant - started, result.rows_affected, nil)
```

Call `record_statement` from the ORM's after-query hook. Pass `[] of String`, or `?` for each bound value, as `params`
unless you mean to show the values.

### CQL on PostgreSQL: things to know

* Use `Model(Int64)` with `primary :id, Int64`, and `class` for models.
* Indexes declared in `schema.table` (`index [...]`, a column's `index: true`) are created with the table.
* `CQL::Migrator` writes the database URI into `src/schemas/app_schema.cr` while `auto_sync` is on; pass
  `MigratorConfig.new(auto_sync: false)`. Its tracking table is `cql_schema_migrations`.
* Pass association foreign keys explicitly: `has_many :posts, Post, foreign_key: :user_id`.
  `delete!` applies `dependent:`, and `preload` works for `has_many`, `has_one` and `belongs_to`.
* `CRYSTAL_ENV` must be set before CQL's configuration is first created: its environment defaults (pool sizes, SSL) are applied
  at that moment, not when `c.env` is assigned.

### Naming gotcha

`include Azu` makes `Azu::CQL` visible as `CQL` inside your namespace, and CQL's own macros expand `CQL::ActiveRecord::...` there.
`azu/cql` therefore mirrors every `::CQL` type into `Azu::CQL`, so models keep working. Inside your own code, prefer `::CQL::...` when you mean the ORM.

```crystal
require "sqlite3"
require "azu/cql"

module Shop
  include Azu

  Db = Azu::CQL.schema(:shop, "sqlite3://./shop.db") do
    table :orders do
      primary :id, Int64
      column :total, Float64
    end
  end

  class Order
    include CQL::ActiveRecord::Model(Int64) # resolves to Azu::CQL::ActiveRecord::Model, the same module
    db_context Db, :orders

    property total : Float64

    def initialize(@total : Float64)
    end
  end

  Order.where { total > 100.0 }.all
end
```

## Limits

* The store is one per process and in memory: the last 2,000 statements and 200 transactions. N+1 detection sees only
  those.
* The SQL playground accepts one statement, reads 10,000 bytes of body and returns 200 rows, for loopback clients only.
* `azu/cql` needs CQL 0.0.609 or newer, the version Azu's `shard.yml` asks for. The compile-time check is looser: it needs
  `CQL::Telemetry.subscribe_transactions` and `CQL::Schema#pool_stats`, which first shipped in 0.0.541, and an older
  release fails to compile with a message saying so. Some of the tab needs a newer CQL:

| CQL provides | Dashboard shows | Since |
| --- | --- | --- |
| `QueryEvent` `sql`, `duration`, `rows_affected`, `error`, `operation`, `adapter` | timing badge, rows (writes only: a SELECT shows "-"), error, operation, database | 0.0.541 |
| `QueryEvent#params` (only with `Telemetry.capture_params`) | `?` placeholders; the values only with `database.show_params` | 0.0.541 |
| `QueryEvent#context` (`Telemetry.with_context("job:x")`) | a `tag:` line under the SQL | 0.0.541 |
| `QueryEvent#pool_wait` | "waited N ms for a connection" on slow statements, a "Pool waits" fact on the pool card | 0.0.798 |
| `TransactionEvent` Begin, Commit, Rollback with `id`, `duration`, `nested`, `error` | the Transactions card; statements inside are counted per transaction | 0.0.541 |
| `Schema#pool_stats` (`open`, `idle`, `in_flight`, `max`) | the pool meter and counters | 0.0.541 |
| `Schema#source` (`DatabaseSource`, `Postgres::EngineSource`) | "Connections" on the pool card | 0.0.609 |
| A nested `schema.transaction` is a SAVEPOINT on the outer connection | statements of the inner block are attributed to it; "(nested)" in the card | 0.0.626 |

## See also

- [Use the dev dashboard](../how-to/performance/use-dev-dashboard.md)
- [CQL bridge](api/cql-bridge.md)
- [Optimize database queries](../how-to/performance/optimize-database-queries.md)
- [Dev tools](dev/azu-dev.md)

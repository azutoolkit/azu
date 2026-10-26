# Azu playground

Small apps that run against the Azu source in this repository. Run `shards install` once in the repository root, then
start them from there. They need Crystal 1.22.1 or newer and the SQLite library (`libsqlite3-dev` on Debian/Ubuntu,
`brew install sqlite` on macOS). The [Examples](../docs/examples.md) page describes each one.

| App | Command (from the repository root) | Open |
| --- | --- | --- |
| Example app: endpoints, pages, forms, cache, a WebSocket channel | `crystal run playground/example_app.cr` | <http://127.0.0.1:4000> |
| The same with the dev dashboard and the performance monitor | `PERFORMANCE_MONITORING=true crystal run playground/example_app.cr` | <http://127.0.0.1:4000/dev-dashboard> |
| Azu + CQL on SQLite: the dashboard's Database tab | `crystal run playground/azu_cql_demo.cr` | <http://127.0.0.1:4000/__dev> |
| Azu + CQL on PostgreSQL | `DATABASE_URL=postgres://... crystal run playground/azu_cql_postgres/app.cr` | <http://127.0.0.1:4000/__dev> |
| Spark live components | `crystal run playground/spark_demo/app.cr` | <http://127.0.0.1:3000> |

`examples/` holds single-file scripts (`crystal run playground/examples/direct_log_test.cr`). Every one of them
compiles and runs to completion (CI type-checks them); `server_exception_test.cr` listens on `PORT`, or on a free port
when it is not set. [docs/examples.md](../docs/examples.md#scripts) says what each one shows.

## Azu + CQL demo: live SQL tracing

`azu_cql_demo.cr` is a small app that shows the **Database** tab of the Azu dev dashboard.
It runs on a local SQLite file, so you need no database server.

```bash
crystal run playground/azu_cql_demo.cr
```

The server listens on <http://127.0.0.1:4000>; the dashboard is at <http://127.0.0.1:4000/__dev>.
The database file `playground/azu_cql_demo.db` is recreated and re-seeded on every start.

### Generate traffic

In another terminal:

```bash
curl 127.0.0.1:4000/users                          # users + posts, preloaded: 2 queries, no N+1
curl 127.0.0.1:4000/users/n_plus_one               # deliberate N+1: one posts query per user
curl -X POST "127.0.0.1:4000/users?name=Ada"       # CRUD insert
curl -X DELETE 127.0.0.1:4000/users/6              # CRUD delete
curl -X POST "127.0.0.1:4000/transfer?commit=true"   # transaction that commits
curl -X POST "127.0.0.1:4000/transfer?commit=false"  # transaction that rolls back
curl 127.0.0.1:4000/slow                           # slow query (red badge)
```

### What to look at in the dashboard

Open <http://127.0.0.1:4000/__dev> and choose **Database** in the sidebar. The page refreshes itself every 15 seconds
(or press the refresh button); the filter box at the top (press `/`) narrows the query rows.

| Area | What you see |
| --- | --- |
| KPI cards | total queries, slow queries, N+1 patterns, health score |
| N+1 analysis | the repeated query shape, how many times it ran in one request, the call site (`file:line`) and an eager-loading hint |
| Recent queries | SQL with a time badge, rows, the request and endpoint that ran it, call site, and a **Copy** button |
| Slow queries / Query patterns | slowest statements and the most executed statement shapes |
| Transactions | open / committed / rolled back, number of queries, duration |
| Connection pool | connections in use, open, idle and the limit |
| SQL playground | run a read-only `SELECT`, `EXPLAIN` or `EXPLAIN ANALYZE` against the app database |

The SQL playground is only available in development, to clients on a loopback address.
It accepts one `SELECT`/`WITH`/`EXPLAIN` statement and always rolls back.

This demo mounts the dashboard without the performance monitor, so the request tabs (Overview, Logs, Performance
Tracing) stay empty; the example app with `PERFORMANCE_MONITORING=true` fills them.

### How it is wired

```crystal
require "azu"
require "azu/dev"                      # opt-in dashboard
require "azu/cql"                      # opt-in bridge
require "sqlite3"

module CqlDemo
  include Azu

  DemoDB = Azu::CQL.schema(:cql_demo, "sqlite3://./azu_cql_demo.db") do
    table :users { ... }
  end
end

CqlDemo.start [
  Azu::Handler::RequestId.new,         # request id + request context for SQL tagging
  Azu::Handler::DevDashboard.new("/__dev"),
  ...
]
```

`Azu::CQL.schema` subscribes to CQL's query and transaction events (`CQL::Telemetry`) and attaches the schema to the
dashboard's pool card and SQL playground. Each query is tagged with the request id, endpoint, path and fiber of the
HTTP request that issued it.

> CQL models that reference each other must use fully qualified names inside a namespace
> (`has_many :posts, CqlDemo::Post`) because CQL resolves association targets at compile time.

## Azu + CQL on PostgreSQL

`azu_cql_postgres/` is the same demo on PostgreSQL, laid out like an azu_cli project (initializers load first, then
`db/`): the only Azu/CQL wiring is `initializers/cql_config.cr` (`Azu::CQL.configure` with CQL's own settings, then
`Azu::CQL.attach { AppDB }`). `db/schema.cr` defines the schema with `Azu::CQL.schema`, `models.cr` holds plain CQL
models and `app.cr` the endpoints.

```bash
createdb azu_cql_demo                                  # or point DATABASE_URL at any database
export DATABASE_URL=postgres://postgres@localhost:5432/azu_cql_demo
crystal run playground/azu_cql_postgres/app.cr         # http://127.0.0.1:4000, dashboard at /__dev#database
```

Same curl scenario as above, without the `DELETE`;
`/slow` also logs `Slow query (...ms, limit 50.0ms) in SlowEndpoint: SELECT pg_sleep(0.2)`.

The connection is lazy: `SKIP_SEED=1 crystal run playground/azu_cql_postgres/app.cr` boots without a database (the
Database tab renders, the SQL playground reports the connection error) and the first request after PostgreSQL comes up
connects.

## Spark demo

`spark_demo/app.cr` shows four live components on one page: a counter, an echo field, a 150-row ledger and a chat room
shared by every open tab. It listens on `PORT` (3000) and `HOST` (`127.0.0.1`); with `REDIS_URL` set, chat messages go
through Redis so several processes share one room. Its counter and chat room are the ones the
[Building live components](../docs/tutorials/building-live-components.md) tutorial builds.

## Example app

`example_app.cr` is the general-purpose example: endpoints and request contracts, Jinja pages with i18n and
CSRF-protected forms, the memory cache, a WebSocket channel and error responses. Built and run with
`PERFORMANCE_MONITORING=true` it also mounts the dev dashboard at `/dev-dashboard` with the performance monitor, so
Overview, Logs, Performance Tracing and Cache fill as you use the pages, next to Routes and Config. Its database is
plain crystal-db, so the Database tab stays empty (the CQL demos fill it), and it has no live components for the
Components tab. `/dev-tools?action=generate_test_data` adds sample numbers.

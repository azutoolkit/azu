# Azu playground

## Azu + CQL demo: live SQL tracing

`azu_cql_demo.cr` is a small app that shows the **Database & Queries** tab of the Azu dev dashboard.
It runs on a local SQLite file, so you need no database server.

### Run it

```bash
cd playground
shards install                 # installs azu (path), cql and sqlite3
crystal run azu_cql_demo.cr
```

Needs Crystal 1.17+ and the SQLite dev library (`libsqlite3-dev` on Debian/Ubuntu, `brew install sqlite` on macOS).
The server listens on <http://localhost:4000>; the dashboard is at <http://localhost:4000/__dev>.
The database file `playground/azu_cql_demo.db` is recreated and re-seeded on every start.

### Generate traffic

In another terminal:

```bash
curl localhost:4000/users                          # users + posts, preloaded: 2 queries, no N+1
curl localhost:4000/users/n_plus_one               # deliberate N+1: one posts query per user
curl -X POST "localhost:4000/users?name=Ada"       # CRUD insert
curl -X DELETE localhost:4000/users/6              # CRUD delete
curl -X POST "localhost:4000/transfer?commit=true"   # transaction that commits
curl -X POST "localhost:4000/transfer?commit=false"  # transaction that rolls back
curl localhost:4000/slow                           # slow query (red badge)
```

### What to look at in the dashboard

Open <http://localhost:4000/__dev>, choose **Database** in the sidebar (or press `g` then `d`). The tab updates every 2 seconds without reloading.

| Area | What you see |
| --- | --- |
| KPI cards | total queries, total DB time, N+1 alerts, connection pool usage |
| N+1 banner | the repeated query shape, how many times it ran in one request, the call site (`file:line`) and an eager-loading hint |
| Queries | highlighted SQL, time badge (green < 5 ms, yellow < 50 ms, red slower), rows, endpoint, **Copy** button; click a row for bindings, call site and the request waterfall |
| Filters | minimum duration, table, errors only |
| Transactions | open / committed / rolled back, number of queries, duration |
| SQL Playground | run a read-only `SELECT`, `EXPLAIN` or `EXPLAIN ANALYZE` against the app database |

The SQL playground is only available when `Azu::CONFIG.env` is `Development` and the request comes from localhost.
It accepts one `SELECT`/`WITH`/`EXPLAIN` statement and always rolls back.

### How it is wired

```crystal
require "azu"
require "azu/cql"                      # opt-in bridge

DemoDB = Azu::CQL.schema(:app, "sqlite3://./app.db") do
  table :users { ... }
end

Azu.start [
  Azu::Handler::RequestId.new,         # request id + request context for SQL tagging
  Azu::Handler::DevDashboard.new("/__dev"),
  ...
]
```

`Azu::CQL.schema` subscribes to CQL's `cql.query`, `cql.transaction` and `cql.connect` events.
Each query is tagged with the request id, endpoint, path and fiber of the HTTP request that issued it.

> CQL models that reference each other must use fully qualified names inside a namespace
> (`has_many :posts, CqlDemo::Post`) because CQL resolves association targets at compile time.

## Example app

`example_app.cr` is the general-purpose example (endpoints, components, caching, channels).

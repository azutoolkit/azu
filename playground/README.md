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

Open <http://localhost:4000/__dev> and choose **Database** in the sidebar. The page refreshes itself every 15 seconds (or press the refresh button); the filter box at the top (press `/`) narrows the query rows.

| Area | What you see |
| --- | --- |
| KPI cards | total queries, slow queries, N+1 patterns, health score |
| N+1 analysis | the repeated query shape, how many times it ran in one request, the call site (`file:line`) and an eager-loading hint |
| Recent queries | SQL with a time badge (green < 5 ms, yellow < 50 ms, red slower), rows, the request and endpoint that ran it, call site, and a **Copy** button |
| Slow queries / patterns | slowest statements and the most executed statement shapes |
| Transactions | open / committed / rolled back, number of queries, duration |
| Connection pool | connections in use, open, idle and the limit |
| SQL playground | run a read-only `SELECT`, `EXPLAIN` or `EXPLAIN ANALYZE` against the app database |

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

## Azu + CQL on PostgreSQL

`azu_cql_postgres/` is the same demo on PostgreSQL, laid out like an azu_cli project (initializers load first, then
`db/`): the only Azu/CQL wiring is `initializers/cql_config.cr` (`Azu::CQL.configure` with CQL's own settings, then
`Azu::CQL.attach { AppDB }`). `db/schema.cr` defines the schema with `Azu::CQL.schema`, `models.cr` holds plain CQL
models and `app.cr` the endpoints.

```bash
createdb azu_cql_demo                                  # or point DATABASE_URL at any database
export DATABASE_URL=postgres://postgres@localhost:5432/azu_cql_demo
crystal run azu_cql_postgres/app.cr                    # http://localhost:4000, dashboard at /__dev#database
```

Run `shards install` first (it also installs `pg`). Same curl scenario as above;
`/slow` also logs `Slow query (...ms, limit 50.0ms) in SlowEndpoint: SELECT pg_sleep(0.2)`.

The connection is lazy: `SKIP_SEED=1 crystal run azu_cql_postgres/app.cr` boots without a database (the Database tab renders,
the SQL playground reports the connection error) and the first request after PostgreSQL comes up connects.

## Example app

`example_app.cr` is the general-purpose example (endpoints, components, caching, channels).

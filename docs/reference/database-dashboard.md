# Database dashboard (CQL integration)

The dev dashboard's **Database** tab shows every SQL statement an Azu app runs: KPIs, N+1 analysis,
recent queries tagged with the request that ran them, slow queries, query patterns, transactions,
connection pool usage and a read-only SQL playground.

Without an integration the tab falls back to CQL's own performance monitor (when `cql` is required
before `azu`), or shows an "n/a" card. Once `azu/cql` is installed, the statements recorded in
`Azu::QueryStore` take precedence.

Azu core does not depend on CQL. The integration is opt-in:

```crystal
require "azu"
require "azu/cql"      # add `cql` to your shard.yml dependencies

AppDB = Azu::CQL.schema(:app, "sqlite3://./app.db") do
  table :users do
    primary :id, Int64
    column :name, String
  end
end
# or attach an existing schema:  Azu::CQL.attach(AppDB)
```

## Moving parts

| Piece | Where | Role |
| --- | --- | --- |
| `CQL::Events` | cql `src/events.cr` | `cql.query`, `cql.transaction`, `cql.connect` events; zero cost without subscribers |
| `Azu::CQL::Instrumentor` | `src/azu/cql/instrumentor.cr` | subscribes to the events and records them in `Azu::QueryStore` |
| `Azu::RequestContext` | `src/azu/request_context.cr` | fiber-keyed current request (id, endpoint, method, path); set by `Handler::RequestId` and `Endpoint#call` |
| `Azu::QueryStore` | `src/azu/query_store.cr` | bounded store (2000 queries), N+1 analysis, transactions, pool snapshot |
| `Dashboard::DatabaseData` | `src/azu/components/dev_dashboard/database_data.cr` | numbers for the tab: from `QueryStore` when an integration is installed, else from CQL's monitor |
| `Dashboard::DatabaseSection` | `src/azu/components/dev_dashboard/database_section.cr` | server-rendered cards (queries, transactions, pool, playground) |
| `dashboard.js` | `src/azu/components/dev_dashboard/dashboard.js` | the playground's `fetch`; the tab itself refreshes with the dashboard's soft refresh |
| `Handler::DevDashboard` | `src/azu/handler/dev_dashboard.cr` | serves `POST {path}/sql` for the playground |

Other ORMs can feed the same dashboard by calling `Azu::QueryStore.instance.record_query` and setting an `Azu::DatabaseAdapter`.

## Configuration

```crystal
Azu.configure do |c|
  c.database.uri = "sqlite3://./app.db"  # used by Azu::CQL.schema without a uri (default ENV["DATABASE_URL"])
  c.database.instrument = true           # AZU_DB_INSTRUMENT
  c.database.n_plus_one_threshold = 3    # AZU_DB_N_PLUS_ONE_THRESHOLD
  c.database.slow_query_ms = 50.0        # AZU_DB_SLOW_QUERY_MS
  c.database.playground = true           # AZU_DB_PLAYGROUND
end
```

## N+1 detection

Within one request, a `SELECT` whose normalized shape (literals and bindings replaced by `?`, `IN` lists collapsed)
runs at least `n_plus_one_threshold` times is reported with its count, total time, call site and an eager-load hint.

## SQL playground

The card appears only when the environment is `Development`, a database is attached and `database.playground` is on; the endpoint additionally requires a loopback client.
Requests must be same-origin POSTs with `X-Requested-With: azu-dashboard`. One `SELECT` / `WITH` / `EXPLAIN` statement is accepted
(no comments, no writes), runs in a transaction that is always rolled back, and returns at most 200 rows.

## Naming gotcha

`include Azu` makes `Azu::CQL` visible as `CQL` inside your namespace, and CQL's own macros expand `CQL::ActiveRecord::...` there.
`azu/cql` therefore mirrors every `::CQL` type into `Azu::CQL`, so models keep working. Inside your own code, prefer `::CQL::...` when you mean the ORM.

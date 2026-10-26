---
description: The runnable apps in the repository's playground folder, what each one shows, and the command that starts it.
---

# Examples

The repository's [`playground/`](https://github.com/azutoolkit/azu/blob/master/playground/README.md) folder holds small
apps that run against the Azu source next to them. Clone the repository and install its shards once, from its root:

```bash
git clone https://github.com/azutoolkit/azu.git
cd azu
shards install
```

Every command on this page runs from the repository root. The apps need Crystal 1.22.1 or newer and the SQLite library
(`libsqlite3-dev` on Debian and Ubuntu, `brew install sqlite` on macOS). With `CRYSTAL_ENV` unset they run in
development and listen on `127.0.0.1`.

| Example | Shows | Start it | Open |
| --- | --- | --- | --- |
| [Example app](https://github.com/azutoolkit/azu/blob/master/playground/example_app.cr) | Endpoints and request contracts, Jinja pages with i18n and CSRF-protected forms, the memory cache, a WebSocket channel, error responses | `crystal run playground/example_app.cr` | <http://127.0.0.1:4000> |
| [CQL on SQLite](https://github.com/azutoolkit/azu/blob/master/playground/azu_cql_demo.cr) | The dashboard's Database tab: queries tagged with their request, an N+1 pattern, transactions, a slow query, the SQL playground | `crystal run playground/azu_cql_demo.cr` | <http://127.0.0.1:4000/__dev> |
| [CQL on PostgreSQL](https://github.com/azutoolkit/azu/blob/master/playground/azu_cql_postgres/app.cr) | The same on PostgreSQL, laid out like an `azu new` project | `crystal run playground/azu_cql_postgres/app.cr` | <http://127.0.0.1:4000/__dev> |
| [Spark demo](https://github.com/azutoolkit/azu/blob/master/playground/spark_demo/app.cr) | Live components: a counter, a field the server follows as you type, a 150-row table, a chat room every tab shares | `crystal run playground/spark_demo/app.cr` | <http://127.0.0.1:3000> |

## Example app

`playground/example_app.cr` loads its endpoints, requests, responses, handlers and channels from the folders next to it
and keeps its data in an in-memory SQLite database, so every start is fresh. Its pages are Hello (`/html`), Users (a
form that creates and deletes people), Realtime (the WebSocket channel at `/hi`, which counts who is connected), Cache,
API (the JSON routes, with links) and Errors (one link per error response).

To add the dev dashboard and the performance monitor, set `PERFORMANCE_MONITORING=true` for the build and for the run,
which `crystal run` does in one go:

```bash
PERFORMANCE_MONITORING=true crystal run playground/example_app.cr
```

Then open <http://127.0.0.1:4000/dev-dashboard>, or <http://127.0.0.1:4000/dev-tools?action=generate_test_data> to
fill it with sample numbers. Without `CSRF_SECRET` the forms are signed with a random key per process, and Azu logs a
warning saying so.

## CQL on SQLite

`playground/azu_cql_demo.cr` recreates and seeds `playground/azu_cql_demo.db` on every start and always listens on
port 4000. Send it some traffic, then open the **Database** tab:

```bash
curl 127.0.0.1:4000/users                          # users and their posts, preloaded: no N+1
curl 127.0.0.1:4000/users/n_plus_one               # one posts query per user: an N+1 alert
curl -X POST "127.0.0.1:4000/users?name=Ada"       # insert
curl -X DELETE 127.0.0.1:4000/users/6              # delete
curl -X POST "127.0.0.1:4000/transfer?commit=true"   # a transaction that commits
curl -X POST "127.0.0.1:4000/transfer?commit=false"  # a transaction that rolls back
curl 127.0.0.1:4000/slow                           # a slow query, also logged as a warning
```

## CQL on PostgreSQL

`playground/azu_cql_postgres/` is the same demo on PostgreSQL, laid out like a generated project: `initializers/`
configures CQL and attaches the dashboard, `db/schema.cr` defines the schema, `models.cr` holds the models and `app.cr`
the endpoints. It runs on CQL's native PostgreSQL engine, so it needs no `pg` driver.

```bash
createdb azu_cql_demo
DATABASE_URL=postgres://postgres@localhost:5432/azu_cql_demo crystal run playground/azu_cql_postgres/app.cr
```

`DATABASE_URL` defaults to `postgres://localhost/azu_cql_demo`. Each start drops and seeds the tables; `SKIP_SEED=1`
keeps the data and lets the app boot without a database, since the connection opens on the first query. It has the
routes of the SQLite demo except `DELETE /users/:id`. See [Database dashboard](reference/database-dashboard.md) for
the setup it shows.

## Spark demo

`playground/spark_demo/app.cr` renders four live components on one page over one WebSocket per tab: a counter whose
value survives a reconnect, an echo field, a ledger table that pages through 150 rows, and a chat room. Open two tabs to
see the chat shared. It listens on `PORT` (3000 by default) and `HOST` (`127.0.0.1` by default). With `REDIS_URL` set,
chat messages go through Redis, so several processes share one room:

```bash
REDIS_URL=redis://localhost:6379/0 crystal run playground/spark_demo/app.cr
```

Set `SPARK_SECRET` when you run it anywhere but your machine: without it the demo signs its tokens with a fixed demo
secret. [Building live components](tutorials/building-live-components.md) builds similar components step by step.

## Scripts

`playground/examples/` holds single-file scripts that print to the terminal; run one with
`crystal run playground/examples/<file>`.

| Script | Shows | Status |
| --- | --- | --- |
| `direct_log_test.cr` | How Azu's log format prints exceptions | Runs |
| `exception_test.cr` | The same for exceptions without a message, nested ones and warnings | Runs |
| `final_endpoint_logging_demo.cr` | The endpoint class name the request logger prints | Runs |
| `async_logging_example.cr` | `Azu::AsyncLogging::AsyncLogger` with request ids, batches and error reporting; `Azu::AsyncLogging.shutdown` writes what is queued | Runs |
| `server_exception_test.cr` | An exception raised in an endpoint, as the logger records it (listens on `PORT`, or a free port) | Runs |
| `cache_metrics_demo.cr` | Cache operations recorded in `PerformanceMetrics` | Runs |
| `performance_reporter_demo.cr` | The performance reporters, including a custom CSV one | Runs |

CI type-checks every script in `playground/examples/` (`crystal build --no-codegen`).

## See also

- [Getting started](tutorials/getting-started.md)
- [Use the dev dashboard](how-to/performance/use-dev-dashboard.md)
- [Database dashboard](reference/database-dashboard.md)

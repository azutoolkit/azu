# Azu + CQL + PostgreSQL playground

A small blog API (users, posts, comments) that shows the whole database workflow on PostgreSQL:
models, migrations, seeds, `db:*` tasks, preloading, pagination, transactions, soft deletes, and the
dev dashboard's **Database** tab (query stream, N+1 analysis, transactions, pool, SQL playground).

The only configuration is the `DATABASE_URL` environment variable.

## 1. Start PostgreSQL

```bash
docker compose up -d db          # postgres:16 on localhost:5432
cp .env.example .env && export $(cat .env | xargs)
```

Already have Postgres? Point `DATABASE_URL` at it instead
(`postgres://user:password@host:5432/azu_blog_development`).

## 2. Install and create the database

```bash
shards install
crystal run db/tasks.cr -- setup     # create + migrate + seed
crystal run db/tasks.cr -- status    # which migrations ran
```

Every task is also available after `shards build tasks` as `bin/tasks <command>`. `help` lists them:

| Command | What it does |
| --- | --- |
| `create` / `drop` / `setup` / `reset` | Database lifecycle (`drop` needs `--force` in production) |
| `migrate [VERSION]` / `rollback [STEPS]` / `redo` | Run, revert or repeat migrations (`--dry-run` prints the SQL) |
| `status` / `version` | Applied and pending migrations |
| `seed` | Runs the blocks in `db/seeds.cr` |
| `structure:dump` / `structure:load` | `db/structure.sql` through `pg_dump` / `psql` |
| `analyze` | Health report: largest tables, unused/duplicate/invalid indexes, dead rows, cache hit ratio (`--refresh` runs `ANALYZE`) |

Add `--verbose` to see the SQL each command runs.

## 3. Run the app

```bash
crystal run src/app.cr               # http://localhost:4000
open http://localhost:4000/__dev#database
```

## 4. Try it

```bash
curl "localhost:4000/users?page=1&per_page=3"            # paginate + preload: 2 queries + the count
curl -X POST localhost:4000/users -d "name=Ada&email=ada@example.com"
curl -X POST localhost:4000/users -d "name=A&email=nope"  # 422 with validation messages
curl -X PUT  localhost:4000/users/6 -d "name=Ada Lovelace"
curl localhost:4000/posts                                  # published posts, authors + comments preloaded
curl localhost:4000/posts/n_plus_one                       # deliberate N+1: watch the log and the dashboard
curl -X DELETE  localhost:4000/posts/1                     # soft delete
curl -X POST    localhost:4000/posts/1/restore
curl -X POST localhost:4000/signup -d "email=a@b.co&fail=true"   # transaction rolls back
curl -X POST localhost:4000/signup -d "email=a@b.co"             # ...and commits
curl localhost:4000/health                                 # database ping + pool counters
```

## What to look at

| Where | What it shows |
| --- | --- |
| `src/models/*.cr` | `Azu::Model`: `table`, `column`, `timestamps`, `soft_delete`, `validates`, `has_many`/`belongs_to`, `scope`, UUID and JSONB columns |
| `db/migrations/*.cr` | `Azu::Migration` DSL: `create_enum`, `t.references`, partial and GIN indexes, `CREATE INDEX CONCURRENTLY` (migration 4 opts out of the DDL transaction) |
| `src/api.cr` | `User.recent.preload(:posts).paginate(...)`, `User.transaction { \|tx\| User.create!(tx, ...) }`, `Post.restore!` |
| `/__dev#database` | Every statement with the request and call site that ran it, N+1 patterns, transactions, pool, SQL playground (read-only + `EXPLAIN`) |
| log output | `N+1 query: Post#user was loaded lazily ...; add preload(:user)` (set `c.database.n_plus_one` to `Off`, `Warn` or `Raise`) |

## Notes

* Deleting a user cascades in the database (`on_delete: :cascade` in the migrations); soft-deleted posts
  are ordinary rows as far as PostgreSQL is concerned, so the foreign key is what keeps things consistent.
* `bin/tasks` and `bin/app` come from `shards build`; the `crystal run` forms need no build step.

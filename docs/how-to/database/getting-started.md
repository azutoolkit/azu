# A PostgreSQL Database in 5 Minutes

`azu/database` gives an Azu app models, migrations, seeds, `db:*` tasks and the dev dashboard's
Database tab with one URL of configuration. It is opt-in: apps that do not `require "azu/database"`
never load CQL or a database driver.

A complete, runnable version of this guide is in
[`playground/azu_postgres_app`](https://github.com/azutoolkit/azu/tree/master/playground/azu_postgres_app).

## 1. Add the shards

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
  cql:
    github: azutoolkit/cql
  pg:
    github: will/crystal-pg
    version: ~> 0.29.0
```

## 2. Point Azu at the database

```bash
export DATABASE_URL=postgres://postgres:postgres@localhost:5432/blog_development
```

That is all the configuration there is. Without it Azu falls back to `AZU_DB_*` / `PG*` variables and
then to `postgres://localhost/<app>_<env>`. To set it in code, or tune the pool:

```crystal
Azu.configure do |c|
  c.database.url = "postgres://localhost/blog_development"
  c.database.pool_size = 10
  c.database.slow_query_ms = 50
  c.database.n_plus_one = Azu::DatabaseConfiguration::NPlusOne::Warn # Off | Warn | Raise
end
```

The pool opens lazily (or at boot), the schema is learned from your models, and queries appear in
`/__dev#database` automatically.

## 3. Declare a model

```crystal
# src/models/user.cr
class User < Azu::Model
  table :users

  column id : Int64, primary_key: true
  column email : String, validate: :email, unique: true
  column name : String
  column role : String = "member"
  timestamps

  validates :name, presence: true, length: 2..80
  has_many posts : Post, foreign_key: :user_id
  scope :admins, -> { where(role: "admin") }
end
```

See [Models](../../reference/database/models.md) for every macro.

## 4. Write the migration

```crystal
# db/migrations/20261022000001_create_users.cr
class CreateUsers < Azu::Migration(20261022000001_i64)
  def up
    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :role, default: "member"
      t.timestamps
      t.index :email, unique: true
    end
  end

  def down
    drop_table :users
  end
end
```

See [Migrations](../../reference/database/migrations.md) for the PostgreSQL types, index options and
online-safe operations.

## 5. Add the task runner

```crystal
# db/tasks.cr
require "pg"
require "azu"
require "azu/database"
require "../src/models"
require "./migrations/*"
require "./seeds"

exit Azu::Database::Tasks.run(ARGV)
```

```bash
crystal run db/tasks.cr -- setup     # create + migrate + seed
crystal run db/tasks.cr -- status
```

[Database tasks](../../reference/database/tasks.md) lists every command, including `structure:dump`,
`structure:load` and `analyze`.

## 6. Use it

```crystal
user = User.create!(email: "ada@example.com", name: "Ada")
User.admins.recent.preload(:posts).paginate(page: 2, per_page: 20) # => Azu::Page(User)

User.transaction do |tx|
  author = User.create!(tx, email: "bob@example.com", name: "Bob")
  Post.create!(tx, user_id: author.id.not_nil!, title: "Hello")
end
```

Start the app with `Azu::Handler::DevDashboard.new("/__dev")` in the handler list and open
`/__dev#database` to see every statement, the request and call site that ran it, N+1 patterns,
transactions, pool usage and a read-only SQL playground with `EXPLAIN`.

## Good to know

* Declare `table` and the `primary_key` column first; associations and validations come after.
* Write association targets as full constant paths inside namespaces (`Blog::Post`).
* `column` accepts `String`, `Int32`, `Int64`, `Float64`, `Bool`, `Time`, `UUID` and `JSON::Any`
  (json/jsonb). Array columns are not mapped by models yet: use migrations and raw SQL for them.
* The migration builder lives in `Azu::Migrations` because a top-level `Azu::Schema` would shadow the
  `schema` shard Azu depends on.

# Migrations (`Azu::Migration`, `Azu::Migrator`)

PostgreSQL-first migrations: plain Crystal classes with a small DSL that emits SQL.

```crystal
# db/migrations/20261022000002_create_posts.cr
class CreatePosts < Azu::Migration(20261022000002_i64)
  def up
    create_enum :post_status, %w(draft published archived)

    create_table :posts do |t|
      t.references :user, on_delete: :cascade
      t.string :title
      t.text :body, default: ""
      t.enum_column :status, :post_status, default: "draft"
      t.jsonb :meta, default_sql: "'{}'::jsonb"
      t.timestamps
      t.soft_delete
      t.index :created_at, where: "status = 'published' AND deleted_at IS NULL"
      t.index :meta, using: :gin
    end
  end

  def down
    drop_table :posts
    drop_enum :post_status
  end
end
```

The number is the version (a timestamp such as `20261022000002`); it orders migrations and must be
unique. `Azu::Migrator` records applied versions in `schema_migrations`.

## Table builder

Columns are `NOT NULL` unless `null: true`.

| Method | Column type |
| --- | --- |
| `string` (`limit:`), `text`, `citext` | `varchar(255)`, `text`, `citext` |
| `integer`, `smallint`, `bigint`, `float`, `decimal(precision:, scale:)` | numeric types |
| `boolean`, `uuid`, `json`, `jsonb`, `hstore`, `inet`, `binary` | as named |
| `date`, `time`, `datetime` | `date`, `time`, `timestamptz` |
| `array :tags, of: :text` | `text[]` (`index: true` adds a GIN index) |
| `enum_column :status, :post_status` | a type made with `create_enum` |
| `references :user, on_delete: :cascade` | `user_id bigint`, foreign key and index |
| `timestamps`, `soft_delete` | `created_at`/`updated_at` default `now()`; nullable `deleted_at` |
| `column :name, :type, ...` | anything else |

Column options: `null`, `default:` (a literal), `default_sql:` (an expression such as `gen_random_uuid()`),
`unique`, `check`, `index`. Table-level: `t.foreign_key`, `t.unique([...])`, `t.check("...")`,
`t.index(columns, unique:, name:, using:, where:, covering:, opclass:, expression:)`.
`using:` takes `:btree`, `:hash`, `:gin`, `:gist`, `:spgist`, `:brin`.

## Changing tables

`add_column`, `remove_column`, `rename_column`, `rename_table`, `change_column_null`,
`change_column_default`, `change_column_type(..., using:)`, `add_index`, `remove_index`,
`add_foreign_key` / `validate_foreign_key` / `remove_foreign_key`,
`add_check_constraint` / `validate_check_constraint` / `remove_check_constraint`,
`create_enum` / `add_enum_value` / `drop_enum`, `enable_extension` / `disable_extension`, `drop_table`,
and `execute "SQL"` for anything else.

## Doing it online

* `add_index :comments, [:post_id, :created_at], concurrent: true` builds without blocking writes.
  PostgreSQL forbids this inside a transaction, so declare `disable_ddl_transaction!` in the migration
  (using `concurrent: true` otherwise raises a clear error).
* `add_foreign_key ..., validate: false` and `add_check_constraint ..., validate: false` add the
  constraint `NOT VALID` (no table scan); finish with `validate_foreign_key` / `validate_check_constraint`.
* Expression indexes: `add_index :users, [] of Symbol | String, expression: "lower(email)", name: "users_lower_email"`.

## Running

```crystal
migrator = Azu::Migrator.new
migrator.migrate                      # everything pending
migrator.migrate(to: 20261022000002_i64)
migrator.rollback(2)                  # last two, newest first
migrator.rollback_to(0_i64)           # everything
migrator.redo
migrator.status                       # Array(Azu::Migrator::Status)
migrator.pending.size
```

* Each migration runs in its own transaction (a failure leaves no trace and its version unrecorded),
  unless it calls `disable_ddl_transaction!`.
* A session advisory lock serialises concurrent runs, so several instances can boot at once.
* `migrate(dry_run: true)` collects the SQL (`migrator.statements`) without touching the database.
* In development the app logs a warning at boot when migrations are pending.
* `Azu::Migrator.new(table: :other_table, migrations: [CreateUsers, ...])` limits the runner.

In practice you use the [database tasks](tasks.md): `migrate`, `rollback`, `redo`, `status`.

---
description: Create and run database migrations with CQL.
---

# Run migrations

A migration is a class that subclasses `CQL::Migration(version)`, where the version is a unique integer, a timestamp
(`YYYYMMDDHHMMSS`) in the files the generator writes. Defining the class registers it with `CQL::Migrator`, which
applies migrations in version order and records each one in the `cql_schema_migrations` table. The migration receives
the schema as `schema`.

Before you start: a project made by `azu new`. Its schema file declares every table with its current columns, and
the migrations in `src/db/migrations/` change the database to match. The examples on this page migrate this schema,
starting from the migration that creates `users`:

<!-- prelude -->
```crystal
# src/initializers/cql_config.cr
require "sqlite3"
require "azu/cql"

Azu::CQL.configure do |c|
  c.db = ENV["DATABASE_URL"]? || "sqlite3://./db/acme.db"
end

# src/db/schema.cr
AcmeDB = Azu::CQL.schema :acme do
  table :users do
    primary :id, Int64
    text :name
    text :email
    timestamps
  end

  table :posts do
    primary :id, Int64
    bigint :user_id
    text :title
    text :content
    boolean :published, default: false
    integer :views, default: 0
    timestamps

    foreign_key :user_id, references: :users, on_delete: :cascade
  end
end

# src/db/migrations/20260115103045_create_users.cr
class CreateUsers < CQL::Migration(20260115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      text :name
      text :email
      timestamps
    end
    schema.users.create!

    schema.alter :users do
      create_index :index_users_on_email, [:email], unique: true
    end
  end

  def down
    schema.users.drop!
  end
end
```

`schema.alter` raises (`Table 'users' not found`) and `schema.users` fails unless the table is declared in the schema
file: a migration's own `schema.table` declares it only in the process that runs that migration.

## Generate a migration

`azu generate model Post ...` writes a model and the migration that creates its table, and adds the table to
`src/db/schema.cr`. `azu generate migration` writes a migration on its own, named after what it does:

```bash
azu generate migration CreateUsers name:string email:string
azu generate migration AddAgeToUsers age:int32
```

The file is `src/db/migrations/<timestamp>_<name>.cr`, and the name decides the body: `CreateUsers` creates the
`users` table from the attributes (and declares it in `src/db/schema.cr`), `AddAgeToUsers` and `RemoveAgeFromUsers`
add or drop the listed columns. Read the file before you run it.

## Creating a table

`CreateUsers` above declares the table in the migration, then creates it. Declaring it first is what makes
`schema.users` available. `schema.users.create!` runs `CREATE TABLE IF NOT EXISTS`, then creates the indexes declared
inside the `table` block (`index [...]`, `index: true`; see [Define a schema](define-schema.md#indexes)); `drop!` runs
`DROP TABLE`. `create_index` inside `schema.alter` adds an index to a table that already exists.

A table with a foreign key is created the same way:

```crystal
class CreatePosts < CQL::Migration(20260116090000_i64)
  def up
    schema.table :posts do
      primary :id, Int64
      bigint :user_id
      text :title
      text :content
      boolean :published, default: false
      integer :views, default: 0
      timestamps

      foreign_key :user_id, references: :users, on_delete: :cascade
    end
    schema.posts.create!
  end

  def down
    schema.posts.drop!
  end
end
```

## Changing a table

Changes to existing tables go through `schema.alter`. Each call inside the block is turned into SQL and run in one
transaction when the block ends.

### Add column

`add_column` columns are nullable unless you pass `null: false` with a `default:`:

```crystal
class AddBioAndAgeToUsers < CQL::Migration(20260117090000_i64)
  def up
    schema.alter :users do
      add_column :bio, String, null: true
      add_column :age, Int32, null: false, default: 0
    end
  end

  def down
    schema.alter :users do
      drop_column :bio
      drop_column :age
    end
  end
end
```

### Remove column

```crystal
class RemoveLegacyFieldFromUsers < CQL::Migration(20260118090000_i64)
  def up
    schema.alter :users do
      drop_column :legacy_field
    end
  end

  def down
    schema.alter :users do
      add_column :legacy_field, String, null: true
    end
  end
end
```

### Rename column

```crystal
class RenameUsersNameToFullName < CQL::Migration(20260119090000_i64)
  def up
    schema.alter :users do
      rename_column :name, :full_name
    end
  end

  def down
    schema.alter :users do
      rename_column :full_name, :name
    end
  end
end
```

### Change column type

`change_column` takes the column name and its new type. SQLite cannot alter a column and raises
`CQL::SQLiteUnsupportedFeatureError` (with the table-rebuild workaround in its message); PostgreSQL and MySQL support it:

```crystal
class WidenPostsViews < CQL::Migration(20260120090000_i64)
  def up
    schema.alter :posts do
      change_column :views, Int64
    end
  end

  def down
    schema.alter :posts do
      change_column :views, Int32
    end
  end
end
```

### Create index

`create_index` takes an index name, the columns and `unique:`; `drop_index` takes the name:

```crystal
class AddPostIndexes < CQL::Migration(20260121090000_i64)
  def up
    schema.alter :posts do
      create_index :index_posts_on_user_id_and_created_at, [:user_id, :created_at]
      create_index :index_posts_on_title, [:title], unique: true
    end
  end

  def down
    schema.alter :posts do
      drop_index :index_posts_on_user_id_and_created_at
      drop_index :index_posts_on_title
    end
  end
end
```

### Add foreign key

SQLite can only declare foreign keys in `CREATE TABLE`; adding or dropping one afterwards raises. Use this on
PostgreSQL or MySQL:

```crystal
class AddAuthorToPosts < CQL::Migration(20260122090000_i64)
  def up
    schema.alter :posts do
      foreign_key :user_id, references: :users, on_delete: :cascade, name: :fk_posts_user
    end
  end

  def down
    schema.alter :posts do
      drop_foreign_key :fk_posts_user
    end
  end
end
```

### Rename table

```crystal
class RenamePostsToArticles < CQL::Migration(20260123090000_i64)
  def up
    schema.alter :posts do
      rename_table :articles
    end
  end

  def down
    schema.alter :articles do
      rename_table :posts
    end
  end
end
```

### Drop table

```crystal
class DropLegacyData < CQL::Migration(20260124090000_i64)
  def up
    schema.legacy_data.drop!
  end

  def down
    schema.table :legacy_data do
      primary :id, Int64
      column :data, String
    end
    schema.legacy_data.create!
  end
end
```

After a migration changes a table, change its declaration in `src/db/schema.cr` and the model's properties to match.

## Running migrations

The CLI loads `src/initializers`, `src/db/schema.cr` and `src/db/migrations/*`, and runs `CQL::Migrator` with
`auto_sync` off:

```bash
azu db:migrate                            # apply every pending migration
azu db:migrate --version 20260120090000   # apply the pending ones up to and including this version
azu db:status                             # applied and pending migrations
azu db:rollback                           # undo the newest migration
azu db:rollback --steps 3                 # undo the three newest
```

`azu db:setup` creates the database and migrates it (`--seed` also seeds it); `azu db:reset` drops, recreates,
migrates and seeds it (`--no-seed` skips the seeds).

{% hint style="warning" %}
`azu db:migrate --steps N` (CQL's `up(steps)`) applies the pending migrations among the first N in version order, not
the next N pending ones. `azu db:rollback --version V` (CQL's `down_to`) rolls back as many of the newest migrations
as there are versions up to and including V, not the ones newer than V. Migrate with `--version` and roll back with
`--steps`.
{% endhint %}

### From code

The same calls are available on the migrator, for a task or a test. `schema.migrator(config)` is shorthand for
`CQL::Migrator.new(schema, config)`; require the migration files first, because each class registers itself when it
is defined:

```crystal
migrator = AcmeDB.migrator(CQL::MigratorConfig.new(auto_sync: false))

migrator.up                           # apply every pending migration
migrator.up_to(20260120090000_i64)    # apply the pending ones up to and including this version
migrator.rollback                     # undo the newest migration
migrator.rollback(steps: 3)           # undo the three newest
migrator.redo                         # undo the newest migration, then apply every pending one
migrator.down                         # roll back everything
migrator.print_pending_migrations
migrator.print_applied_migrations
```

`migrator.last` returns the most recent migration class, and `migrator.pending_migrations` /
`migrator.applied_migrations` return the lists without printing them.

## Schema file synchronisation

By default (`auto_sync: true`) the migrator writes a schema file from the live database after running migrations, in
plain CQL (see [Without Azu](define-schema.md#without-azu)) and with the database URI in it. The generated `src/db/schema.cr` is kept by hand (and by the
generators), so the CLI turns `auto_sync` off. To dump the database to a file of its own, name the path and constants:

```crystal
config = CQL::MigratorConfig.new(
  schema_file_path: "src/db/dumped_schema.cr",
  schema_name: :DumpedSchema,
  schema_symbol: :dumped_schema,
  auto_sync: true
)

AcmeDB.migrator(config).up
```

The default path is `src/schemas/app_schema.cr`.

{% hint style="danger" %}
The dumped file contains the database URI, so keep credentials out of it (read them from the environment) or leave
`auto_sync` off.
{% endhint %}

## Migration best practices

### Version numbers

The version is the `Migration(...)` argument; the file name is only for humans. Timestamps keep migrations from
different branches apart, and the generator picks the next free one when two are generated in the same second:

```text
src/db/migrations/
├── 20260115103045_create_users.cr
├── 20260116090000_create_posts.cr
├── 20260117090000_add_bio_and_age_to_users.cr
└── 20260121090000_add_post_indexes.cr
```

### Reversible migrations

Always implement both `up` and `down`:

```crystal
class AddRoleToUsers < CQL::Migration(20260125090000_i64)
  def up
    schema.alter :users do
      add_column :role, String, null: false, default: "user"
    end
  end

  def down
    schema.alter :users do
      drop_column :role
    end
  end
end
```

### Data migrations

A migration can change rows as well as tables. `schema.exec` runs one SQL string without parameters:

```crystal
class BackfillUserSlugs < CQL::Migration(20260126090000_i64)
  def up
    schema.alter :users do
      add_column :slug, String, null: true
    end

    # Backfill existing records
    schema.exec("UPDATE users SET slug = lower(replace(name, ' ', '-'))")
  end

  def down
    schema.alter :users do
      drop_column :slug
    end
  end
end
```

To keep data changes apart from schema changes, `azu generate data:migration BackfillUserSlugs` writes a migration to
`src/db/data_migrations/`, and `azu db:data:migrate` runs those.

### Batch updates

For large tables update in batches, binding the values through the connection with `exec_query`:

```crystal
class AddWordCountToPosts < CQL::Migration(20260127090000_i64)
  def up
    schema.alter :posts do
      add_column :word_count, Int32, null: false, default: 0
    end

    batch_size = 1000
    loop do
      updated = schema.exec_query do |connection|
        connection.exec(<<-SQL, batch_size).rows_affected
          UPDATE posts
          SET word_count = length(content) - length(replace(content, ' ', '')) + 1
          WHERE word_count = 0 AND id IN (SELECT id FROM posts WHERE word_count = 0 LIMIT ?)
        SQL
      end

      break if updated == 0
    end
  end

  def down
    schema.alter :posts do
      drop_column :word_count
    end
  end
end
```

## See also

- [Define a schema](define-schema.md)
- [Create models](create-models.md)
- [Working with databases](../../tutorials/working-with-databases.md)

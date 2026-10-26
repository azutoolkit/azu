# Run migrations

This guide shows you how to create and run database migrations with CQL.

A migration is a class that subclasses `CQL::Migration(version)`, where the version is a unique integer, usually a
timestamp (`YYYYMMDDHHMMSS`). Defining the class registers it with `CQL::Migrator`, which applies migrations in version
order and records each one in the `cql_schema_migrations` table. The migration receives the schema as `schema`.

## Creating a Migration

Declare the table on the schema, then create it. Declaring it first is what makes `schema.users` available:

```crystal
require "cql"

# db/migrations/20240115103045_create_users.cr
class CreateUsers < CQL::Migration(20240115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      column :name, String
      column :email, String
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

`schema.users.create!` runs `CREATE TABLE IF NOT EXISTS`; `drop!` runs `DROP TABLE`. Indexes declared inside the `table`
block are not created (see [Define Schema](define-schema.md#indexes)), so create them with `create_index` as above.

## Migration Operations

Changes to existing tables go through `schema.alter`. Each call inside the block is turned into SQL and run in one
transaction when the block ends.

### Create Table

```crystal
require "cql"

class CreatePosts < CQL::Migration(20240116090000_i64)
  def up
    schema.table :posts do
      primary :id, Int64
      column :user_id, Int64
      column :title, String
      column :content, String
      column :published, Bool, default: false
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

### Add Column

`add_column` columns are nullable unless you pass `null: false` with a `default:`:

```crystal
require "cql"

class AddBioAndAgeToUsers < CQL::Migration(20240117090000_i64)
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

### Remove Column

```crystal
require "cql"

class RemoveLegacyFieldFromUsers < CQL::Migration(20240118090000_i64)
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

### Rename Column

```crystal
require "cql"

class RenameUsersNameToFullName < CQL::Migration(20240119090000_i64)
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

### Change Column Type

`change_column` takes the column name and its new type. SQLite cannot alter a column and raises
`CQL::SQLiteUnsupportedFeatureError` (with the table-rebuild workaround in its message); PostgreSQL and MySQL support it:

```crystal
require "cql"

class WidenPostsViews < CQL::Migration(20240120090000_i64)
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

### Create Index

`create_index` takes an index name, the columns and `unique:`; `drop_index` takes the name:

```crystal
require "cql"

class AddPostIndexes < CQL::Migration(20240121090000_i64)
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

### Add Foreign Key

SQLite can only declare foreign keys in `CREATE TABLE`; adding or dropping one afterwards raises. Use this on
PostgreSQL or MySQL:

```crystal
require "cql"

class AddAuthorToPosts < CQL::Migration(20240122090000_i64)
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

### Rename Table

```crystal
require "cql"

class RenamePostsToArticles < CQL::Migration(20240123090000_i64)
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

### Drop Table

```crystal
require "cql"

class DropLegacyData < CQL::Migration(20240124090000_i64)
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

## Running Migrations

`CQL::Migrator` is created from the schema. `schema.migrator(config)` is shorthand for `CQL::Migrator.new(schema, config)`.
Require the migration files before running it, because each class registers itself when it is defined:

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
end

class CreateUsers < CQL::Migration(20240115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      column :name, String
    end
    schema.users.create!
  end

  def down
    schema.users.drop!
  end
end

migrator = AppDB.migrator(CQL::MigratorConfig.new(auto_sync: false))

migrator.up                           # apply every pending migration
migrator.up(steps: 1)                 # apply the next one only
migrator.print_pending_migrations
migrator.print_applied_migrations
```

### Run from the Command Line

A small task file keeps the commands in your project (`crystal run src/tasks/db.cr -- migrate`):

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: ENV.fetch("DATABASE_URL", "sqlite3://./db/development.db")) do
end

# In a project: require "../../db/migrations/*"
class CreateUsers < CQL::Migration(20240115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      column :name, String
    end
    schema.users.create!
  end

  def down
    schema.users.drop!
  end
end

migrator = AppDB.migrator(CQL::MigratorConfig.new(auto_sync: false))

case ARGV[0]?
when "migrate"
  migrator.up
  puts "Migrations complete"
when "rollback"
  migrator.rollback(steps: (ARGV[1]? || "1").to_i)
  puts "Rollback complete"
when "redo"
  migrator.redo
when "status"
  migrator.print_applied_migrations
  migrator.print_pending_migrations
when "reset"
  migrator.down
  migrator.up
  puts "Database reset"
else
  puts "Usage: crystal run src/tasks/db.cr -- [migrate|rollback [steps]|redo|status|reset]"
end
```

The Azu CLI (`azu db:migrate`, `azu db:rollback`, `azu db:status`) wraps the same migrator; see the CLI's own
documentation for its options.

### Rollback

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
end

class CreateUsers < CQL::Migration(20240115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      column :name, String
    end
    schema.users.create!
  end

  def down
    schema.users.drop!
  end
end

migrator = AppDB.migrator(CQL::MigratorConfig.new(auto_sync: false))

migrator.rollback                     # undo the last migration
migrator.rollback(steps: 3)           # undo the last three
migrator.redo                         # roll back the last one and apply it again
migrator.down_to(20240117090000_i64)  # roll back everything newer than this version
migrator.up_to(20240120090000_i64)    # apply up to and including this version
migrator.down                         # roll back everything
```

`migrator.last` returns the most recent migration class, and `migrator.pending_migrations` /
`migrator.applied_migrations` return the lists without printing them.

## Schema File Synchronisation

By default (`auto_sync: true`) the migrator regenerates a schema file after running migrations, from the live
database. Configure where it writes and what it is called:

```crystal
require "cql"
require "sqlite3"

AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::SQLite, uri: "sqlite3://./db/development.db") do
end

class CreateUsers < CQL::Migration(20240115103045_i64)
  def up
    schema.table :users do
      primary :id, Int64
      column :name, String
    end
    schema.users.create!
  end

  def down
    schema.users.drop!
  end
end

config = CQL::MigratorConfig.new(
  schema_file_path: "src/db/schema.cr",
  schema_name: :AppSchema,
  schema_symbol: :app_schema,
  auto_sync: true
)

AppDB.migrator(config).up
```

The generated file contains the database URI, so keep credentials out of it (read them from the environment) or turn
`auto_sync` off. The default path is `src/schemas/app_schema.cr`.

## Migration Best Practices

### Version Numbers

Use a timestamp so migrations from different branches do not collide. The version is the `Migration(...)` argument,
the file name is only for humans:

```text
db/migrations/
├── 20240115103045_create_users.cr
├── 20240116090000_create_posts.cr
├── 20240117090000_add_bio_and_age_to_users.cr
└── 20240121090000_add_post_indexes.cr
```

### Reversible Migrations

Always implement both `up` and `down`:

```crystal
require "cql"

class AddRoleToUsers < CQL::Migration(20240125090000_i64)
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

### Data Migrations

`schema.exec` runs one SQL string without parameters. To bind values, use the connection with `exec_query`:

```crystal
require "cql"

class BackfillUserSlugs < CQL::Migration(20240126090000_i64)
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

### Batch Updates

For large tables update in batches, binding the values through the connection:

```crystal
require "cql"

class AddWordCountToPosts < CQL::Migration(20240127090000_i64)
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

## See Also

- [Define Schema](define-schema.md)
- [Create Models](create-models.md)

# How to Run Migrations

This guide shows you how to create and run database migrations with CQL.

## Creating a Migration

Create a migration file:

```crystal
# db/migrations/001_create_users.cr
class CreateUsers < CQL::Migration
  def up
    create_table :users do
      primary :id, Int64
      column :name, String
      column :email, String
      timestamps
    end

    create_index :users, :email, unique: true
  end

  def down
    drop_table :users
  end
end
```

## Migration Operations

### Create Table

```crystal
def up
  create_table :posts do
    primary :id, Int64
    column :user_id, Int64
    column :title, String
    column :content, String
    column :published, Bool, default: false
    timestamps

    foreign_key :user_id, :users, :id
  end
end
```

### Add Column

```crystal
def up
  add_column :users, :bio, String?
  add_column :users, :age, Int32, default: 0
end

def down
  remove_column :users, :bio
  remove_column :users, :age
end
```

### Remove Column

```crystal
def up
  remove_column :users, :legacy_field
end

def down
  add_column :users, :legacy_field, String?
end
```

### Rename Column

```crystal
def up
  rename_column :users, :name, :full_name
end

def down
  rename_column :users, :full_name, :name
end
```

### Change Column

```crystal
def up
  change_column :posts, :content, String, null: true
end

def down
  change_column :posts, :content, String, null: false
end
```

### Create Index

```crystal
def up
  create_index :users, :email, unique: true
  create_index :posts, [:user_id, :created_at]
end

def down
  drop_index :users, :email
  drop_index :posts, [:user_id, :created_at]
end
```

### Add Foreign Key

```crystal
def up
  add_foreign_key :posts, :user_id, :users, :id
end

def down
  remove_foreign_key :posts, :user_id
end
```

### Rename Table

```crystal
def up
  rename_table :posts, :articles
end

def down
  rename_table :articles, :posts
end
```

### Drop Table

```crystal
def up
  drop_table :legacy_data
end

def down
  create_table :legacy_data do
    primary :id, Int64
    column :data, String
  end
end
```

## Running Migrations

### Run All Pending

```crystal
# In your application or CLI
CQL::Migrator.new(AcmeDB).migrate
```

### Run from Command Line

```bash
# Using a custom CLI tool
crystal run src/cli.cr -- db:migrate
```

Example CLI:

```crystal
# src/cli.cr
require "./db/schema"
require "./db/migrations/*"

case ARGV[0]?
when "db:migrate"
  CQL::Migrator.new(AcmeDB).migrate
  puts "Migrations complete"
when "db:rollback"
  CQL::Migrator.new(AcmeDB).rollback
  puts "Rollback complete"
when "db:reset"
  CQL::Migrator.new(AcmeDB).reset
  puts "Database reset"
else
  puts "Usage: crystal run src/cli.cr -- [db:migrate|db:rollback|db:reset]"
end
```

### Rollback Last Migration

```crystal
CQL::Migrator.new(AcmeDB).rollback
```

### Rollback Multiple

```crystal
CQL::Migrator.new(AcmeDB).rollback(steps: 3)
```

### Reset Database

```crystal
# Rollback all and re-migrate
CQL::Migrator.new(AcmeDB).reset
```

## Migration Best Practices

### Numbered Migrations

Name migrations with timestamps or sequence numbers:

```
db/migrations/
├── 001_create_users.cr
├── 002_create_posts.cr
├── 003_add_bio_to_users.cr
└── 004_create_comments.cr
```

### Reversible Migrations

Always implement both `up` and `down`:

```crystal
class AddRoleToUsers < CQL::Migration
  def up
    add_column :users, :role, String, default: "user"
  end

  def down
    remove_column :users, :role
  end
end
```

### Data Migrations

Handle data in migrations carefully:

```crystal
class BackfillUserSlugs < CQL::Migration
  def up
    add_column :users, :slug, String?

    # Backfill existing records
    AcmeDB.exec("UPDATE users SET slug = lower(replace(name, ' ', '-'))")

    # Make non-nullable after backfill
    change_column :users, :slug, String
  end

  def down
    remove_column :users, :slug
  end
end
```

### Batch Updates

For large tables, update in batches:

```crystal
def up
  add_column :posts, :word_count, Int32, default: 0

  # Update in batches
  offset = 0
  batch_size = 1000

  loop do
    result = AcmeDB.exec(<<-SQL, offset, batch_size)
      UPDATE posts
      SET word_count = length(content) - length(replace(content, ' ', '')) + 1
      WHERE id IN (SELECT id FROM posts LIMIT ? OFFSET ?)
    SQL

    break if result.rows_affected == 0
    offset += batch_size
  end
end
```

## See Also

- [Define Schema](define-schema.md)
- [Create Models](create-models.md)

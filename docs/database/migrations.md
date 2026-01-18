# Migrations

Migrations manage database schema changes in a version-controlled, reversible way.

## Creating Migrations

Migrations are numbered classes with `up` and `down` methods:

```crystal
# db/migrations/001_create_users.cr
class CreateUsers < CQL::Migration(1)
  def up
    schema.create :users do
      primary :id, Int64, auto_increment: true
      text :name, null: false
      text :email, null: false
      boolean :active, default: "true"
      timestamps

      index :email, unique: true
    end
  end

  def down
    schema.users.drop!
  end
end
```

## Migration Methods

### Creating Tables

```crystal
def up
  schema.create :posts do
    primary :id, Int64, auto_increment: true
    text :title, null: false
    text :content
    text :slug
    bigint :user_id, null: false
    boolean :published, default: "false"
    timestamp :published_at, null: true
    timestamps

    index :user_id
    index :slug, unique: true
    index :published
  end
end
```

### Dropping Tables

```crystal
def down
  schema.posts.drop!
end
```

### Adding Columns

```crystal
class AddAvatarToUsers < CQL::Migration(2)
  def up
    schema.users.alter do
      add_column :avatar_url, String, null: true
      add_column :bio, String, null: true
    end
  end

  def down
    schema.users.alter do
      drop_column :avatar_url
      drop_column :bio
    end
  end
end
```

### Removing Columns

```crystal
class RemoveLegacyFields < CQL::Migration(3)
  def up
    schema.users.alter do
      drop_column :legacy_id
      drop_column :old_email
    end
  end

  def down
    schema.users.alter do
      add_column :legacy_id, Int32, null: true
      add_column :old_email, String, null: true
    end
  end
end
```

### Adding Indexes

```crystal
class AddIndexesToPosts < CQL::Migration(4)
  def up
    schema.posts.alter do
      add_index :created_at
      add_index [:user_id, :published]
    end
  end

  def down
    schema.posts.alter do
      drop_index :created_at
      drop_index [:user_id, :published]
    end
  end
end
```

### Renaming Columns

```crystal
class RenameNameToFullName < CQL::Migration(5)
  def up
    schema.users.alter do
      rename_column :name, :full_name
    end
  end

  def down
    schema.users.alter do
      rename_column :full_name, :name
    end
  end
end
```

### Changing Column Types

```crystal
class ChangeContentToText < CQL::Migration(6)
  def up
    schema.posts.alter do
      change_column :content, :text  # Change to TEXT type
    end
  end

  def down
    schema.posts.alter do
      change_column :content, :varchar  # Revert to VARCHAR
    end
  end
end
```

## Running Migrations

```crystal
# Run all pending migrations
AppDB.migrate!

# Rollback last migration
AppDB.rollback!

# Rollback specific number of migrations
AppDB.rollback!(steps: 3)

# Get current migration version
version = AppDB.current_version
```

## Migration Best Practices

### Reversible Migrations

Always implement both `up` and `down`:

```crystal
class AddCategoryToPosts < CQL::Migration(7)
  def up
    schema.posts.alter do
      add_column :category, String, null: true, default: "general"
    end
  end

  def down
    schema.posts.alter do
      drop_column :category
    end
  end
end
```

### Data Migrations

Migrate data alongside schema changes:

```crystal
class SplitNameIntoFirstLast < CQL::Migration(8)
  def up
    # Add new columns
    schema.users.alter do
      add_column :first_name, String, null: true
      add_column :last_name, String, null: true
    end

    # Migrate data
    AppDB.execute <<-SQL
      UPDATE users
      SET first_name = split_part(name, ' ', 1),
          last_name = split_part(name, ' ', 2)
      WHERE name IS NOT NULL
    SQL

    # Remove old column
    schema.users.alter do
      drop_column :name
    end
  end

  def down
    schema.users.alter do
      add_column :name, String, null: true
    end

    AppDB.execute <<-SQL
      UPDATE users
      SET name = concat(first_name, ' ', last_name)
    SQL

    schema.users.alter do
      drop_column :first_name
      drop_column :last_name
    end
  end
end
```

### Add Columns as Nullable

```crystal
# Safe: add as nullable first
def up
  schema.users.alter do
    add_column :verified_at, Time, null: true
  end
end
```

## Complete Example

```crystal
# db/migrations/001_create_users.cr
class CreateUsers < CQL::Migration(1)
  def up
    schema.create :users do
      primary :id, Int64, auto_increment: true
      text :email, null: false
      text :password_digest, null: false
      text :name
      boolean :admin, default: "false"
      boolean :active, default: "true"
      timestamps

      index :email, unique: true
    end
  end

  def down
    schema.users.drop!
  end
end

# db/migrations/002_create_posts.cr
class CreatePosts < CQL::Migration(2)
  def up
    schema.create :posts do
      primary :id, Int64, auto_increment: true
      text :title, null: false
      text :content
      text :slug
      bigint :user_id, null: false
      boolean :published, default: "false"
      timestamps

      index :user_id
      index :slug, unique: true
    end
  end

  def down
    schema.posts.drop!
  end
end

# db/migrations/003_add_views_to_posts.cr
class AddViewsToPosts < CQL::Migration(3)
  def up
    schema.posts.alter do
      add_column :view_count, Int32, default: "0"
    end
  end

  def down
    schema.posts.alter do
      drop_column :view_count
    end
  end
end
```

## Next Steps

- [Schema Definition](schema-definition.md) - Define initial schema
- [Models](models.md) - Map models to migrated tables

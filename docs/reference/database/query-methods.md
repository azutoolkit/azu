# Query Methods Reference

Reference for CQL query methods.

## Retrieval Methods

### all

Get all matching records.

```crystal
users = User.all                        # All users
users = User.where(active: true).all    # Filtered
```

**Returns:** `Array(T)`

### first

Get first record.

```crystal
user = User.first                       # First by primary key
user = User.order(name: :asc).first     # First alphabetically
user = User.where(active: true).first   # First active
```

**Returns:** `T?`

### last

Get last record.

```crystal
user = User.last
user = User.order(created_at: :asc).last
```

**Returns:** `T?`

### find

Find by primary key.

```crystal
user = User.find(1)      # Raises if not found
user = User.find?(1)     # Returns nil if not found
```

**Returns:** `T` or `T?`

### find_by

Find by attributes.

```crystal
user = User.find_by(email: "alice@example.com")
user = User.find_by?(email: "alice@example.com")
```

**Returns:** `T` or `T?`

### take

Get n records.

```crystal
users = User.take(5)    # First 5 records
```

**Returns:** `Array(T)`

## Filtering

### where

Filter by conditions.

```crystal
# Hash conditions
User.where(active: true)
User.where(role: "admin", active: true)

# SQL conditions
User.where("age > ?", 18)
User.where("created_at > ?", 1.week.ago)
User.where("name LIKE ?", "%smith%")

# IN clause
User.where("id IN (?)", [1, 2, 3])

# NULL check
User.where("deleted_at IS NULL")
```

**Returns:** Query builder (chainable)

### where.not

Exclude matching records.

```crystal
User.where.not(role: "admin")
User.where.not("status IN (?)", ["banned", "suspended"])
```

### or

Combine conditions with OR.

```crystal
User.where(role: "admin").or(User.where(role: "moderator"))
```

## Ordering

### order

Sort results.

```crystal
User.order(name: :asc)
User.order(created_at: :desc)
User.order(role: :asc, name: :asc)  # Multiple columns
User.order("LOWER(name) ASC")       # Raw SQL
```

**Returns:** Query builder (chainable)

### reorder

Replace previous ordering.

```crystal
User.order(name: :asc).reorder(created_at: :desc)
```

### reverse_order

Reverse current ordering.

```crystal
User.order(name: :asc).reverse_order  # Now desc
```

## Limiting

### limit

Limit number of results.

```crystal
User.limit(10)
User.where(active: true).limit(5)
```

**Returns:** Query builder (chainable)

### offset

Skip records.

```crystal
User.offset(20)
User.limit(10).offset(20)  # Page 3
```

**Returns:** Query builder (chainable)

## Selection

### select

Select specific columns.

```crystal
User.select(:id, :name)
User.select("id, name, email")
User.select("*, LENGTH(bio) as bio_length")
```

### distinct

Return unique records.

```crystal
User.select(:role).distinct
```

### pluck

Get array of column values.

```crystal
emails = User.pluck(:email)        # => ["a@b.com", "c@d.com"]
data = User.pluck(:id, :name)      # => [[1, "Alice"], [2, "Bob"]]
```

**Returns:** `Array`

### ids

Get array of primary key values.

```crystal
user_ids = User.where(active: true).ids  # => [1, 2, 3]
```

**Returns:** `Array(PrimaryKeyType)`

## Aggregation

### count

Count records.

```crystal
User.count                       # Total users
User.where(active: true).count   # Active users
User.count(:email)               # Non-null emails
User.distinct.count(:role)       # Unique roles
```

**Returns:** `Int64`

### sum

Sum column values.

```crystal
Order.sum(:total)
Order.where(user_id: 1).sum(:total)
```

**Returns:** `Number`

### average

Average column values.

```crystal
User.average(:age)
Product.average(:price)
```

**Returns:** `Float64?`

### minimum

Get minimum value.

```crystal
Product.minimum(:price)
User.minimum(:created_at)
```

**Returns:** Column type or nil

### maximum

Get maximum value.

```crystal
Product.maximum(:price)
User.maximum(:age)
```

**Returns:** Column type or nil

## Grouping

### group

Group results.

```crystal
User.select("role, COUNT(*) as count").group(:role)
Order.select("user_id, SUM(total) as total").group(:user_id)
```

### having

Filter groups.

```crystal
User.select("role, COUNT(*) as count")
    .group(:role)
    .having("COUNT(*) > ?", 5)
```

## Joining

### join

Inner join tables.

```crystal
Post.join(:users, "users.id = posts.user_id")
Post.join(:users, "users.id = posts.user_id")
    .select("posts.*, users.name as author_name")
```

### left_join

Left outer join.

```crystal
User.left_join(:posts, "posts.user_id = users.id")
    .select("users.*, COUNT(posts.id) as post_count")
    .group("users.id")
```

### includes

Eager load associations.

```crystal
Post.includes(:author)
User.includes(:posts, :comments)
```

## Existence

### exists?

Check if records exist.

```crystal
User.where(email: "alice@example.com").exists?
User.exists?(email: "alice@example.com")
```

**Returns:** `Bool`

### any?

Check if any records match.

```crystal
User.where(role: "admin").any?
```

**Returns:** `Bool`

### none?

Check if no records match.

```crystal
User.where(role: "banned").none?
```

**Returns:** `Bool`

### empty?

Check if result set is empty.

```crystal
User.where(active: false).empty?
```

**Returns:** `Bool`

## Batch Processing

### find_each

Process records in batches.

```crystal
User.find_each(batch_size: 1000) do |user|
  process(user)
end
```

### in_batches

Process batches.

```crystal
User.in_batches(of: 1000) do |batch|
  batch.update_all(notified: true)
end
```

## Scopes

### scope

Define reusable queries.

```crystal
class User
  scope :active, -> { where(active: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_role, ->(role : String) { where(role: role) }
end

User.active.recent.all
User.by_role("admin").count
```

## Chaining

All query methods are chainable:

```crystal
User.where(active: true)
    .where("age >= ?", 18)
    .order(name: :asc)
    .limit(10)
    .offset(20)
    .all
```

## Raw SQL

### query

Execute raw SELECT.

```crystal
results = MyDB.query("SELECT * FROM users WHERE age > ?", 18)
```

### exec

Execute raw statement.

```crystal
MyDB.exec("UPDATE users SET active = ? WHERE id = ?", true, 1)
```

## See Also

- [CQL API Reference](cql-api.md)
- [How to Query Data](../../how-to/database/query-data.md)

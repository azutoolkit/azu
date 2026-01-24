# How to Optimize Database Queries

This guide shows you how to improve database performance in your Azu application.

## Use Indexes

Add indexes for frequently queried columns:

```crystal
# In migration
def up
  create_index :users, :email, unique: true
  create_index :posts, :user_id
  create_index :posts, [:user_id, :created_at]
  create_index :orders, :status
end
```

## Analyze Query Plans

Check how queries are executed:

```crystal
# PostgreSQL
AcmeDB.query("EXPLAIN ANALYZE SELECT * FROM users WHERE email = 'test@example.com'")

# Look for:
# - Sequential Scan (bad for large tables)
# - Index Scan (good)
# - Index Only Scan (best)
```

## Avoid N+1 Queries

### The Problem

```crystal
# Bad: N+1 queries
posts = Post.all
posts.each do |post|
  puts post.author.name  # One query per post!
end
```

### The Solution

```crystal
# Good: Eager loading
posts = Post.includes(:author).all
posts.each do |post|
  puts post.author.name  # No additional queries
end
```

### Using Joins

```crystal
# Load posts with authors in one query
posts = Post
  .join(:users, "users.id = posts.user_id")
  .select("posts.*, users.name as author_name")
  .all
```

## Select Only Needed Columns

```crystal
# Bad: Loads all columns
users = User.all

# Good: Loads only needed columns
users = User.select(:id, :name, :email).all

# For large text/blob columns especially
posts = Post.select(:id, :title, :created_at).all  # Skip body column
```

## Use Batch Processing

Process large datasets in batches:

```crystal
# Bad: Loads all records into memory
User.all.each do |user|
  process(user)
end

# Good: Process in batches
User.find_each(batch_size: 1000) do |user|
  process(user)
end

# Or with explicit batching
User.in_batches(of: 1000) do |batch|
  batch.each { |user| process(user) }
end
```

## Optimize COUNT Queries

```crystal
# Bad: Loads all records to count
users = User.where(active: true).all
count = users.size

# Good: Count in database
count = User.where(active: true).count
```

## Use Exists Instead of Count

```crystal
# Bad: Counts all matching records
has_orders = Order.where(user_id: user.id).count > 0

# Good: Stops at first match
has_orders = Order.where(user_id: user.id).exists?
```

## Limit Result Sets

```crystal
# Bad: No limit
recent_posts = Post.order(created_at: :desc).all

# Good: Always limit
recent_posts = Post.order(created_at: :desc).limit(10).all
```

## Use Database-Level Operations

```crystal
# Bad: Ruby iteration
users = User.all
total = users.sum(&.balance)

# Good: Database aggregation
total = User.sum(:balance)

# Other aggregations
average = User.average(:age)
max_price = Product.maximum(:price)
min_date = Order.minimum(:created_at)
```

## Batch Updates

```crystal
# Bad: Individual updates
users.each do |user|
  user.update!(last_notified: Time.utc)
end

# Good: Single update query
User.where(id: user_ids).update_all(last_notified: Time.utc)
```

## Batch Inserts

```crystal
# Bad: Individual inserts
records.each do |data|
  User.create!(data)
end

# Good: Bulk insert
User.insert_all(records)
```

## Use Prepared Statements

Prepared statements are cached and reused:

```crystal
# CQL uses prepared statements by default
User.where(email: email).first
```

## Connection Pooling

Configure appropriate pool size:

```crystal
AcmeDB = CQL::Schema.define(:acme_db,
  adapter: CQL::Adapter::Postgres,
  uri: ENV["DATABASE_URL"],
  pool_size: ENV.fetch("DB_POOL_SIZE", "20").to_i,
  checkout_timeout: 5.seconds
)
```

Rule of thumb: `pool_size = (num_cores * 2) + 1`

## Query Caching

Cache expensive queries:

```crystal
def expensive_stats
  cache_key = "stats:#{Date.today}"

  Azu.cache.fetch(cache_key, expires_in: 1.hour) do
    {
      total_users: User.count,
      active_users: User.where(active: true).count,
      total_orders: Order.count,
      revenue: Order.sum(:total)
    }.to_json
  end
end
```

## Use Read Replicas

Route reads to replicas:

```crystal
module DB
  PRIMARY = connect(ENV["DATABASE_URL"])
  REPLICA = connect(ENV["DATABASE_REPLICA_URL"])

  def self.read
    REPLICA
  end

  def self.write
    PRIMARY
  end
end

# Usage
users = DB.read { User.all }
DB.write { user.save! }
```

## Optimize Specific Patterns

### Pagination

```crystal
# Bad: OFFSET with large values
User.offset(10000).limit(20).all  # Scans 10,020 rows

# Good: Cursor-based pagination
last_id = params["after_id"]?.try(&.to_i64) || 0
User.where("id > ?", last_id).limit(20).order(id: :asc).all
```

### Search

```crystal
# Bad: LIKE with leading wildcard
User.where("name LIKE ?", "%smith%")  # Can't use index

# Good: Full-text search or trigram
User.where("name ILIKE ?", "smith%")  # Can use index

# Better: Full-text search
User.where("to_tsvector('english', name) @@ plainto_tsquery('english', ?)", search_term)
```

### Date Ranges

```crystal
# Bad: Function on indexed column
Order.where("DATE(created_at) = ?", date)  # Can't use index

# Good: Range query
Order.where("created_at >= ? AND created_at < ?", date.at_beginning_of_day, date.tomorrow.at_beginning_of_day)
```

## Monitor Query Performance

Log slow queries:

```crystal
class QueryLogger
  @@slow_threshold = 100.milliseconds

  def self.log(sql : String, duration : Time::Span)
    if duration > @@slow_threshold
      Log.warn { "Slow query (#{duration.total_milliseconds}ms): #{sql}" }
    end
  end
end
```

## See Also

- [Optimize Endpoints](optimize-endpoints.md)
- [Query Data](../database/query-data.md)

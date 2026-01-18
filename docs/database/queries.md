# Queries

CQL provides a type-safe query builder for constructing database queries with compile-time validation.

## Basic Queries

### Finding Records

```crystal
# Find by ID
user = User.find(1)          # Raises RecordNotFound if missing
user = User.find?(1)         # Returns nil if missing

# Find by attributes
user = User.find_by(email: "alice@example.com")
user = User.find_by?(email: "alice@example.com")  # Returns nil

# Get all records
users = User.all

# First and last
first = User.first
last = User.last
```

### Where Clauses

```crystal
# Simple equality
users = User.where(active: true).all
posts = Post.where(user_id: 1, published: true).all

# Multiple conditions
users = User.where(active: true)
            .where(admin: false)
            .all
```

### Ordering

```crystal
# Single column
users = User.order(created_at: :desc).all
posts = Post.order(title: :asc).all

# Multiple columns
posts = Post.order(published: :desc, created_at: :desc).all
```

### Limiting and Offset

```crystal
# Limit results
users = User.limit(10).all

# Pagination
page = 2
per_page = 20
users = User.offset((page - 1) * per_page)
            .limit(per_page)
            .all
```

## Advanced Queries

### Chaining

```crystal
# Combine multiple query methods
posts = Post.where(published: true)
            .where(user_id: current_user.id)
            .order(created_at: :desc)
            .limit(10)
            .all
```

### Selecting Columns

```crystal
# Select specific columns
emails = User.select(:id, :email).all

# Select with alias
results = User.select(:id, :name).where(active: true).all
```

### Distinct

```crystal
# Unique values
categories = Post.select(:category).distinct.all
```

### Counting

```crystal
# Count all
total = User.count

# Count with conditions
active_count = User.where(active: true).count
```

### Aggregations

```crystal
# Sum
total_views = Post.sum(:view_count)

# Average
avg_age = User.where(active: true).avg(:age)

# Min/Max
oldest = User.min(:created_at)
newest = User.max(:created_at)
```

### Existence Check

```crystal
# Check if records exist
has_admins = User.where(admin: true).exists?
```

## Joins

```crystal
# Inner join
posts = Post.joins(:user)
            .where(users: { active: true })
            .all

# Join with conditions
posts = Post.joins(:user)
            .where(published: true)
            .where(users: { admin: false })
            .order(created_at: :desc)
            .all
```

## Raw Queries

For complex queries not supported by the query builder:

```crystal
# Execute raw SQL
results = AppDB.query.raw("SELECT * FROM users WHERE age > ?", 18).all

# With type mapping
users = User.from_sql("SELECT * FROM users WHERE created_at > ?", 1.week.ago)
```

## Query Scopes

Define reusable query fragments in models:

```crystal
struct Post
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :posts

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user_id : Int64) { where(user_id: user_id) }
  scope :popular, -> { where("view_count > ?", 1000) }
end

# Use scopes
featured = Post.published.popular.recent.limit(5).all
user_posts = Post.by_author(user.id).published.all

# Chain scopes with other methods
results = Post.published
              .recent
              .limit(10)
              .preload(:user)
              .all
```

## Batching

Process large datasets efficiently:

```crystal
# Process in batches
User.where(active: true).find_each(batch_size: 100) do |user|
  # Process each user
  send_newsletter(user)
end

# Get batches as arrays
User.where(active: true).find_in_batches(batch_size: 100) do |users|
  # Process batch of users
  bulk_update(users)
end
```

## Using with Azu Endpoints

```crystal
struct SearchUsersEndpoint
  include Azu::Endpoint(SearchRequest, UsersResponse)

  get "/users/search"

  def call : UsersResponse
    query = User.where(active: true)

    # Apply search filter
    if search = request.q
      query = query.where("name ILIKE ? OR email ILIKE ?", "%#{search}%", "%#{search}%")
    end

    # Apply sorting
    query = case request.sort
            when "name"  then query.order(name: :asc)
            when "email" then query.order(email: :asc)
            else              query.order(created_at: :desc)
            end

    # Apply pagination
    offset = (request.page - 1) * request.per_page
    users = query.offset(offset).limit(request.per_page).all

    UsersResponse.new(users, total: query.count)
  end
end

struct SearchRequest
  include Azu::Request

  getter q : String?
  getter sort : String = "created_at"
  getter page : Int32 = 1
  getter per_page : Int32 = 20

  validate per_page, numericality: { gt: 0, lte: 100 }
end
```

## Next Steps

- [Relationships](relationships.md) - Query through associations
- [Performance](performance.md) - Optimize query performance

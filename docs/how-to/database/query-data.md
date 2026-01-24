# How to Query Data

This guide shows you how to query data using CQL models.

## Finding Records

### Find by ID

```crystal
user = User.find(1)           # Returns User or raises
user = User.find?(1)          # Returns User or nil
```

### Find by Attributes

```crystal
user = User.find_by(email: "alice@example.com")
user = User.find_by?(email: "alice@example.com")  # Returns nil if not found
```

### Find All

```crystal
users = User.all  # Returns Array(User)
```

### First and Last

```crystal
first_user = User.first
last_user = User.last
oldest = User.order(created_at: :asc).first
```

## Filtering with Where

### Basic Where

```crystal
active_users = User.where(active: true).all
admins = User.where(role: "admin").all
```

### Multiple Conditions

```crystal
users = User.where(active: true, role: "admin").all
```

### Where with Operators

```crystal
# Greater than
adults = User.where("age > ?", 18).all

# Less than or equal
recent = Post.where("created_at >= ?", 1.week.ago).all

# LIKE
users = User.where("name LIKE ?", "%Smith%").all

# IN
users = User.where("role IN (?)", ["admin", "moderator"]).all

# NULL
unverified = User.where("verified_at IS NULL").all
```

### Chaining Where

```crystal
users = User
  .where(active: true)
  .where("age >= ?", 18)
  .where("created_at > ?", 1.month.ago)
  .all
```

## Ordering

```crystal
# Single column
users = User.order(name: :asc).all
users = User.order(created_at: :desc).all

# Multiple columns
users = User.order(role: :asc, name: :asc).all

# Raw SQL
users = User.order("LOWER(name) ASC").all
```

## Limiting and Offsetting

```crystal
# Limit
first_ten = User.limit(10).all

# Offset
page_two = User.limit(10).offset(10).all

# Pagination helper
def paginate(page : Int32, per_page = 20)
  User.limit(per_page).offset((page - 1) * per_page).all
end
```

## Selecting Columns

```crystal
# Select specific columns
names = User.select(:id, :name).all

# Select with alias
data = User.select("id, name as username").all
```

## Aggregations

### Count

```crystal
total = User.count
active_count = User.where(active: true).count
```

### Sum, Average, Min, Max

```crystal
total_orders = Order.sum(:amount)
average_age = User.average(:age)
oldest = User.maximum(:age)
youngest = User.minimum(:age)
```

### Group By

```crystal
# Count by role
User.select("role, COUNT(*) as count")
  .group(:role)
  .all

# Sum by category
Order.select("category, SUM(amount) as total")
  .group(:category)
  .order("total DESC")
  .all
```

## Joins

### Basic Join

```crystal
posts = Post.join(:users, "users.id = posts.user_id")
  .select("posts.*, users.name as author_name")
  .all
```

### Left Join

```crystal
users = User.left_join(:posts, "posts.user_id = users.id")
  .select("users.*, COUNT(posts.id) as post_count")
  .group("users.id")
  .all
```

### Through Associations

```crystal
# Using defined associations
user = User.find(1)
posts = user.posts.where(published: true).all
```

## Scopes

Define reusable queries:

```crystal
class Post
  include CQL::Model(Post, Int64)

  scope :published, -> { where(published: true) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_author, ->(user_id : Int64) { where(user_id: user_id) }
  scope :popular, -> { where("views > ?", 100) }
end

# Use scopes
Post.published.recent.all
Post.by_author(user.id).published.limit(5).all
Post.published.popular.count
```

## Raw SQL

### Execute Raw Query

```crystal
results = AcmeDB.query("SELECT * FROM users WHERE age > ?", 21)
```

### Execute Raw Statement

```crystal
AcmeDB.exec("UPDATE users SET last_login = ? WHERE id = ?", Time.utc, user_id)
```

### Complex Queries

```crystal
sql = <<-SQL
  SELECT u.name, COUNT(p.id) as post_count
  FROM users u
  LEFT JOIN posts p ON p.user_id = u.id
  WHERE u.active = true
  GROUP BY u.id
  HAVING COUNT(p.id) > 5
  ORDER BY post_count DESC
  LIMIT 10
SQL

results = AcmeDB.query(sql)
```

## Eager Loading

Avoid N+1 queries:

```crystal
# Without eager loading (N+1 problem)
posts = Post.all
posts.each { |p| puts p.user.name }  # One query per post!

# With eager loading
posts = Post.includes(:user).all
posts.each { |p| puts p.user.name }  # Single query for users
```

## Existence Checks

```crystal
exists = User.where(email: "alice@example.com").exists?
any = User.where(role: "admin").any?
none = User.where(role: "banned").none?
```

## See Also

- [Create Models](create-models.md)
- [Handle Transactions](handle-transactions.md)

# Database Performance

CQL integrates with Azu's development dashboard to provide database performance monitoring and optimization tools.

## N+1 Query Detection

The development dashboard automatically detects N+1 query patterns when CQL is installed.

### What is N+1?

N+1 occurs when loading associations triggers separate queries for each record:

```crystal
# N+1 problem: 1 query for posts + N queries for users
posts = Post.all
posts.each do |post|
  puts post.user.name  # Query executed for each post
end
```

### Solution: Eager Loading

```crystal
# Single query loads posts with users
posts = Post.preload(:user).all
posts.each do |post|
  puts post.user.name  # No additional query
end
```

## Dashboard Integration

When CQL is available, the development dashboard shows:

- **N+1 Query Alerts**: Detected repeated query patterns
- **Slow Query Log**: Queries exceeding threshold
- **Query Statistics**: Execution counts and timing
- **Database Health Score**: Overall performance indicator

Access the dashboard at `/_dev` in development mode.

## Slow Query Detection

Configure slow query threshold:

```crystal
CQL::Performance.configure do |config|
  config.slow_query_threshold = 100.milliseconds
  config.log_slow_queries = true
end
```

Logged slow queries appear in the dashboard with:
- Query text
- Execution time
- Stack trace origin
- Suggested optimizations

## Query Optimization

### Use Indexes

```crystal
# Schema: Add indexes for frequently queried columns
table :posts do
  primary :id, Int64
  bigint :user_id
  boolean :published
  timestamp :created_at

  index :user_id          # For user.posts queries
  index :published        # For filtering
  index :created_at       # For ordering
  index [:user_id, :published]  # Composite for common filters
end
```

### Select Only Needed Columns

```crystal
# Load full records (slower)
users = User.all

# Load only needed columns (faster)
users = User.select(:id, :name, :email).all
```

### Batch Processing

```crystal
# Process large datasets in batches
User.where(active: true).find_each(batch_size: 100) do |user|
  process(user)
end
```

### Limit Results

```crystal
# Always limit when displaying lists
posts = Post.published
            .order(created_at: :desc)
            .limit(20)
            .all
```

## Connection Pooling

Configure connection pool for high concurrency:

```crystal
AppDB = CQL::Schema.define(
  :app,
  adapter: CQL::Adapter::Postgres,
  uri: ENV["DATABASE_URL"],
  pool_size: 25,          # Maximum connections
  pool_timeout: 5.seconds # Wait timeout
) do
  # tables...
end
```

### Pool Size Guidelines

| App Type | Connections |
|----------|-------------|
| Development | 5 |
| Small production | 10-15 |
| High traffic | 25-50 |
| Per-worker (multi-process) | 5-10 |

## Query Caching

Cache frequently-accessed queries:

```crystal
struct PopularPostsEndpoint
  include Azu::Endpoint(EmptyRequest, PostsResponse)

  get "/posts/popular"

  def call : PostsResponse
    posts = Azu.cache.fetch("popular_posts", ttl: 5.minutes) do
      Post.published
          .order(view_count: :desc)
          .limit(10)
          .preload(:user)
          .all
    end

    PostsResponse.new(posts)
  end
end
```

### Cache Invalidation

```crystal
struct CreatePostEndpoint
  include Azu::Endpoint(PostRequest, PostResponse)

  post "/posts"

  def call : PostResponse
    post = Post.create!(request.to_h)

    # Invalidate related caches
    Azu.cache.delete("popular_posts")
    Azu.cache.delete("user:#{post.user_id}:posts")

    PostResponse.new(post)
  end
end
```

## Monitoring in Production

### Query Logging

```crystal
# Log all queries in development
CQL::Performance.configure do |config|
  config.log_queries = Azu.env.development?
  config.log_slow_queries = true
  config.slow_query_threshold = 200.milliseconds
end
```

### Metrics Collection

```crystal
# Track query metrics
CQL::Performance.on_query do |query, duration|
  if duration > 100.milliseconds
    Log.warn { "Slow query (#{duration.total_milliseconds}ms): #{query}" }
  end

  # Send to metrics service
  Metrics.histogram("db.query.duration", duration.total_milliseconds)
end
```

## Performance Checklist

- [ ] Add indexes for WHERE clause columns
- [ ] Use `preload` for associations
- [ ] Select only needed columns
- [ ] Limit result sets
- [ ] Use query caching for hot data
- [ ] Configure appropriate pool size
- [ ] Monitor slow queries
- [ ] Batch large operations

## Development Dashboard

The Azu development dashboard automatically integrates CQL performance monitoring:

```crystal
# CQL is detected at compile time
{% if @top_level.has_constant?("CQL") %}
  # Full database monitoring enabled
{% end %}
```

Dashboard features when CQL is available:
- Query count per request
- Average query time
- N+1 detection alerts
- Slow query highlighting
- Database connection status

Access via `/_dev/database` in development mode.

## Next Steps

- [Queries](queries.md) - Write efficient queries
- [Relationships](relationships.md) - Optimize association loading
- [Development Dashboard](../advanced/development-dashboard.md) - Full dashboard documentation

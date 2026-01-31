# How to Optimize Endpoints

This guide shows you how to improve the performance of your Azu endpoints.

## Response Caching

Cache frequently accessed data:

```crystal
struct ProductsEndpoint
  include Azu::Endpoint(EmptyRequest, ProductsResponse)

  get "/products"

  CACHE_TTL = 5.minutes

  def call : ProductsResponse
    cache_key = "products:#{cache_params}"

    cached = Azu.cache.get(cache_key)
    return ProductsResponse.from_json(cached) if cached

    products = Product.all
    response = ProductsResponse.new(products)

    Azu.cache.set(cache_key, response.to_json, expires_in: CACHE_TTL)

    response
  end

  private def cache_params
    "page=#{params["page"]? || 1}&limit=#{params["limit"]? || 20}"
  end
end
```

## HTTP Caching Headers

Set cache headers for client-side caching:

```crystal
def call
  product = Product.find(params["id"])

  # Set cache headers
  context.response.headers["Cache-Control"] = "public, max-age=3600"
  context.response.headers["ETag"] = generate_etag(product)

  # Check If-None-Match
  if_none_match = context.request.headers["If-None-Match"]?
  if if_none_match == context.response.headers["ETag"]
    status 304
    return EmptyResponse.new
  end

  ProductResponse.new(product)
end

private def generate_etag(product)
  %("#{product.updated_at.to_unix}")
end
```

## Pagination

Always paginate large collections:

```crystal
struct UsersEndpoint
  include Azu::Endpoint(EmptyRequest, UsersResponse)

  get "/users"

  DEFAULT_LIMIT = 20
  MAX_LIMIT = 100

  def call : UsersResponse
    page = (params["page"]? || "1").to_i
    limit = [(params["limit"]? || DEFAULT_LIMIT.to_s).to_i, MAX_LIMIT].min
    offset = (page - 1) * limit

    users = User.limit(limit).offset(offset).all
    total = User.count

    UsersResponse.new(
      users: users,
      page: page,
      limit: limit,
      total: total,
      total_pages: (total / limit.to_f).ceil.to_i
    )
  end
end
```

## Selective Field Loading

Only load required fields:

```crystal
def call
  fields = params["fields"]?.try(&.split(",")) || ["id", "name", "email"]

  users = User.select(fields.join(", ")).all

  UsersResponse.new(users, fields)
end
```

## Eager Loading

Avoid N+1 queries:

```crystal
# Bad: N+1 queries
def call
  posts = Post.all
  posts.each do |post|
    post.author  # Each access triggers a query
  end
end

# Good: Eager load
def call
  posts = Post.includes(:author).all
  posts.each do |post|
    post.author  # No additional query
  end
end
```

## Parallel Processing

Execute independent operations in parallel:

```crystal
def call
  user_id = params["id"].to_i64

  # Run queries in parallel
  user_channel = Channel(User?).new
  posts_channel = Channel(Array(Post)).new
  stats_channel = Channel(UserStats).new

  spawn { user_channel.send(User.find?(user_id)) }
  spawn { posts_channel.send(Post.where(user_id: user_id).recent.limit(10).all) }
  spawn { stats_channel.send(UserStats.for(user_id)) }

  user = user_channel.receive
  raise Azu::Response::NotFound.new("/users/#{user_id}") unless user

  UserDetailResponse.new(
    user: user,
    posts: posts_channel.receive,
    stats: stats_channel.receive
  )
end
```

## Compression

Compress large responses:

```crystal
class CompressionHandler < Azu::Handler::Base
  MIN_SIZE = 1024  # Only compress > 1KB

  def call(context)
    call_next(context)

    return unless should_compress?(context)

    body = context.response.output.to_s
    return if body.bytesize < MIN_SIZE

    compressed = Compress::Gzip.compress(body)

    if compressed.bytesize < body.bytesize
      context.response.headers["Content-Encoding"] = "gzip"
      context.response.output = IO::Memory.new(compressed)
    end
  end

  private def should_compress?(context) : Bool
    accept = context.request.headers["Accept-Encoding"]?
    return false unless accept
    accept.includes?("gzip")
  end
end
```

## Connection Keep-Alive

Enable persistent connections:

```crystal
context.response.headers["Connection"] = "keep-alive"
context.response.headers["Keep-Alive"] = "timeout=5, max=100"
```

## Response Streaming

Stream large responses:

```crystal
def call
  context.response.content_type = "application/json"
  context.response.headers["Transfer-Encoding"] = "chunked"

  context.response.print "["

  User.find_each(batch_size: 100) do |user, index|
    context.response.print "," if index > 0
    context.response.print user.to_json
    context.response.flush
  end

  context.response.print "]"
end
```

## Async External Calls

Don't block on external services:

```crystal
def call
  # Fire and forget for non-critical operations
  spawn do
    Analytics.track(
      event: "page_view",
      user_id: current_user_id,
      path: context.request.path
    )
  end

  # Return immediately
  MainResponse.new(data)
end
```

## Request Timeouts

Set timeouts for operations:

```crystal
def call
  result = with_timeout(5.seconds) do
    external_api.fetch_data
  end

  DataResponse.new(result)
rescue Timeout::Error
  raise Azu::Response::ServiceUnavailable.new("External service timeout")
end

private def with_timeout(duration : Time::Span, &)
  channel = Channel(typeof(yield)).new

  spawn do
    channel.send(yield)
  end

  select
  when result = channel.receive
    result
  when timeout(duration)
    raise Timeout::Error.new
  end
end
```

## Benchmark Endpoints

Measure endpoint performance:

```crystal
class BenchmarkHandler < Azu::Handler::Base
  def call(context)
    start = Time.instant
    start_gc = GC.stats

    call_next(context)

    duration = Time.instant - start
    end_gc = GC.stats
    allocated = end_gc.heap_size - start_gc.heap_size

    context.response.headers["X-Response-Time"] = "#{duration.total_milliseconds.round(2)}ms"
    context.response.headers["X-Memory-Allocated"] = "#{allocated / 1024}KB"
  end
end
```

## See Also

- [Optimize Database Queries](optimize-database-queries.md)

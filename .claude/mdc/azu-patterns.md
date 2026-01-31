# Azu Development Patterns MDC

> **Domain:** Common Patterns & Implementation Recipes
> **Applies to:** Feature development using Azu framework

## Endpoint Patterns

### Basic CRUD Endpoint

```crystal
# Request contracts
struct CreateUserRequest
  include Azu::Request

  @name : String
  @email : String

  validate name, presence: true, length: {min: 2, max: 100}
  validate email, presence: true, format: /@/
end

struct UpdateUserRequest
  include Azu::Request

  @name : String?
  @email : String?

  validate name, length: {min: 2, max: 100}, allow_nil: true
  validate email, format: /@/, allow_nil: true
end

# Response
struct UserResponse
  include Azu::Response
  include JSON::Serializable

  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email); end

  def render
    to_json
  end
end

# Endpoints
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    req = create_user_request
    raise error("Validation failed", 422, req.errors) unless req.valid?

    user = User.create!(name: req.name, email: req.email)
    status 201
    UserResponse.new(user.id, user.name, user.email)
  end
end

struct GetUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user = User.find(params["id"].to_i64)
    raise error("User not found", 404) unless user

    UserResponse.new(user.id, user.name, user.email)
  end
end
```

### Authenticated Endpoint

```crystal
module AuthenticatedEndpoint(Request, Response)
  include Azu::Endpoint(Request, Response)

  def current_user : User
    @current_user ||= begin
      token = headers["Authorization"]?.try(&.gsub("Bearer ", ""))
      raise error("Authentication required", 401) unless token

      user = User.find_by_token(token)
      raise error("Invalid token", 401) unless user

      user
    end
  end
end

struct ProfileEndpoint
  include AuthenticatedEndpoint(EmptyRequest, UserResponse)

  get "/profile"

  def call : UserResponse
    UserResponse.new(current_user.id, current_user.name, current_user.email)
  end
end
```

### Paginated Response

```crystal
struct PaginatedResponse(T)
  include Azu::Response
  include JSON::Serializable

  getter items : Array(T)
  getter total : Int64
  getter page : Int32
  getter per_page : Int32
  getter total_pages : Int32

  def initialize(@items, @total, @page, @per_page)
    @total_pages = (@total / @per_page).ceil.to_i
  end

  def render
    to_json
  end
end

struct ListUsersEndpoint
  include Azu::Endpoint(EmptyRequest, PaginatedResponse(UserResponse))

  get "/users"

  def call : PaginatedResponse(UserResponse)
    page = (params["page"]? || "1").to_i
    per_page = (params["per_page"]? || "20").to_i.clamp(1, 100)

    users = User.paginate(page, per_page)
    total = User.count

    items = users.map { |u| UserResponse.new(u.id, u.name, u.email) }
    PaginatedResponse(UserResponse).new(items, total, page, per_page)
  end
end
```

## WebSocket Patterns

### Chat Channel

```crystal
class ChatChannel < Azu::Channel
  @@connections = {} of String => HTTP::WebSocket
  @@mutex = Mutex.new

  def on_connect(socket : HTTP::WebSocket)
    user_id = extract_user_id(socket)
    @@mutex.synchronize { @@connections[user_id] = socket }

    broadcast_system("#{user_id} joined")
  end

  def on_message(socket : HTTP::WebSocket, message : String)
    data = JSON.parse(message)
    case data["type"]?
    when "chat"
      broadcast_chat(data["user"].as_s, data["text"].as_s)
    when "typing"
      broadcast_typing(data["user"].as_s)
    end
  end

  def on_close(socket : HTTP::WebSocket)
    user_id = find_user_id(socket)
    @@mutex.synchronize { @@connections.delete(user_id) }

    broadcast_system("#{user_id} left")
  end

  private def broadcast_chat(user : String, text : String)
    broadcast({type: "chat", user: user, text: text, timestamp: Time.utc}.to_json)
  end

  private def broadcast(message : String)
    @@mutex.synchronize do
      @@connections.each_value do |socket|
        socket.send(message) rescue nil
      end
    end
  end
end
```

### Real-Time Component

```crystal
class CounterComponent
  include Azu::Component

  property count : Int32 = 0

  def content
    div do
      h1 { "Count: #{@count}" }
      button({"live-click" => "increment"}) { "+" }
      button({"live-click" => "decrement"}) { "-" }
    end
  end

  def on_event(event : String, payload : JSON::Any)
    case event
    when "increment"
      @count += 1
    when "decrement"
      @count -= 1
    end
    refresh
  end
end
```

## Middleware Patterns

### Rate Limiting by User

```crystal
class UserRateLimiter < Azu::Handler::Base
  LIMITS = {
    "free"    => {requests: 100, window: 1.hour},
    "pro"     => {requests: 1000, window: 1.hour},
    "enterprise" => {requests: 10000, window: 1.hour},
  }

  def call(context : HTTP::Server::Context)
    user = extract_user(context)
    tier = user.try(&.subscription_tier) || "free"
    limit = LIMITS[tier]

    key = "rate_limit:#{user.try(&.id) || context.request.remote_address}"
    count = cache.increment(key)

    if count == 1
      cache.expire(key, limit[:window])
    end

    if count > limit[:requests]
      context.response.status = HTTP::Status::TOO_MANY_REQUESTS
      context.response.headers["Retry-After"] = limit[:window].total_seconds.to_s
      context.response.print({error: "Rate limit exceeded"}.to_json)
      return
    end

    context.response.headers["X-RateLimit-Limit"] = limit[:requests].to_s
    context.response.headers["X-RateLimit-Remaining"] = (limit[:requests] - count).to_s

    call_next(context)
  end
end
```

### Request Logging with Context

```crystal
class ContextualLogger < Azu::Handler::Base
  def call(context : HTTP::Server::Context)
    request_id = context.response.headers["X-Request-ID"]
    start_time = Time.instant

    Log.context.set(
      request_id: request_id,
      method: context.request.method,
      path: context.request.path
    )

    Log.info { "Started #{context.request.method} #{context.request.path}" }

    call_next(context)

    duration = Time.instant - start_time
    Log.info { "Completed #{context.response.status_code} in #{duration.total_milliseconds.round(2)}ms" }
  end
end
```

## Caching Patterns

### Cache-Aside Pattern

```crystal
def get_user(id : Int64) : User?
  cache_key = "user:#{id}"

  # Try cache first
  if cached = cache.get(cache_key)
    return User.from_json(cached)
  end

  # Fetch from database
  user = User.find(id)
  return nil unless user

  # Store in cache
  cache.set(cache_key, user.to_json, ttl: 5.minutes)
  user
end
```

### Cache Invalidation

```crystal
class User
  after_save :invalidate_cache
  after_destroy :invalidate_cache

  private def invalidate_cache
    cache.delete("user:#{id}")
    cache.delete("users:list")
  end
end
```

### Memoization with Cache

```crystal
def expensive_computation(key : String) : Result
  cache.fetch("computation:#{key}", ttl: 1.hour) do
    # Only computed on cache miss
    perform_expensive_work(key)
  end
end
```

## Error Handling Patterns

### Domain-Specific Errors

```crystal
module Errors
  class NotFound < Azu::Response::Error
    def initialize(resource : String, id : String | Int64)
      super("#{resource} with ID #{id} not found", 404)
    end
  end

  class Conflict < Azu::Response::Error
    def initialize(message : String)
      super(message, 409)
    end
  end

  class UnprocessableEntity < Azu::Response::Error
    getter validation_errors : Hash(String, Array(String))

    def initialize(@validation_errors)
      super("Validation failed", 422)
    end

    def to_json
      {error: message, details: @validation_errors}.to_json
    end
  end
end

# Usage in endpoint
def call : UserResponse
  user = User.find(params["id"])
  raise Errors::NotFound.new("User", params["id"]) unless user

  if User.exists?(email: update_request.email)
    raise Errors::Conflict.new("Email already in use")
  end

  # ...
end
```

### Global Error Handler

```crystal
class ErrorHandler < Azu::Handler::Rescuer
  def handle_error(context : HTTP::Server::Context, ex : Exception)
    error_id = UUID.random.to_s
    error_context = ErrorContext.from_http_context(context, error_id)

    case ex
    when Azu::Response::Error
      log_error(ex, error_context, :warn)
      respond_with(context, ex)
    when JSON::ParseException
      log_error(ex, error_context, :info)
      respond_with(context, Errors::UnprocessableEntity.new({"json" => ["Invalid JSON"]}))
    else
      log_error(ex, error_context, :error)
      respond_with(context, Azu::Response::Error.new("Internal server error", 500))
    end
  end

  private def log_error(ex : Exception, ctx : ErrorContext, level : Log::Severity)
    Log.for("errors").log(level) do
      {
        error_id: ctx.request_id,
        message: ex.message,
        backtrace: ex.backtrace?.try(&.first(5)),
        context: ctx.to_h
      }.to_json
    end
  end
end
```

## Testing Patterns

### Endpoint Testing

```crystal
describe CreateUserEndpoint do
  describe "#call" do
    it "creates user with valid data" do
      context = create_context(
        method: "POST",
        path: "/users",
        body: {name: "John", email: "john@example.com"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )

      endpoint = CreateUserEndpoint.new
      response = endpoint.call(context)

      context.response.status_code.should eq 201
      response.name.should eq "John"
    end

    it "returns 422 for invalid email" do
      context = create_context(
        method: "POST",
        path: "/users",
        body: {name: "John", email: "invalid"}.to_json
      )

      expect_raises(Azu::Response::Error) do
        CreateUserEndpoint.new.call(context)
      end.status_code.should eq 422
    end
  end
end
```

### Integration Testing

```crystal
describe "User API" do
  before_all do
    spawn_server
  end

  after_all do
    kill_server
  end

  it "full CRUD workflow" do
    # Create
    response = HTTP::Client.post("http://localhost:4000/users",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: "Test", email: "test@example.com"}.to_json
    )
    response.status_code.should eq 201
    user = JSON.parse(response.body)

    # Read
    response = HTTP::Client.get("http://localhost:4000/users/#{user["id"]}")
    response.status_code.should eq 200

    # Update
    response = HTTP::Client.put("http://localhost:4000/users/#{user["id"]}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: "Updated"}.to_json
    )
    response.status_code.should eq 200

    # Delete
    response = HTTP::Client.delete("http://localhost:4000/users/#{user["id"]}")
    response.status_code.should eq 204
  end
end
```

### WebSocket Testing

```crystal
describe ChatChannel do
  it "broadcasts messages to all connected clients" do
    client1 = HTTP::WebSocket.new("ws://localhost:4000/chat")
    client2 = HTTP::WebSocket.new("ws://localhost:4000/chat")

    received = Channel(String).new

    client2.on_message do |message|
      received.send(message)
    end

    spawn { client2.run }

    client1.send({type: "chat", user: "test", text: "Hello"}.to_json)

    select
    when message = received.receive
      data = JSON.parse(message)
      data["text"].should eq "Hello"
    when timeout(1.second)
      fail "No message received"
    end

    client1.close
    client2.close
  end
end
```

## Configuration Patterns

### Environment-Specific Configuration

```crystal
Azu.configure do |config|
  case config.env
  when .development?
    config.template_hot_reload = true
    config.performance_enabled = true
    config.cache_config.store = "memory"
  when .test?
    config.template_hot_reload = false
    config.cache_config.store = "null"
  when .production?
    config.template_hot_reload = false
    config.cache_config.store = "redis"
    config.cache_config.redis_url = ENV["REDIS_URL"]
  end
end
```

### Feature Flags

```crystal
module Features
  class_getter cache = {} of String => Bool

  def self.enabled?(feature : String) : Bool
    @@cache[feature] ||= begin
      ENV.has_key?("FEATURE_#{feature.upcase}")
    end
  end
end

# Usage
if Features.enabled?("new_search")
  NewSearchEndpoint.register
else
  LegacySearchEndpoint.register
end
```

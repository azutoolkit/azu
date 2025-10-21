# Response Objects

Response objects structure and format the output of your Azu endpoints. They provide type-safe, consistent responses with proper serialization and content type handling.

## What are Response Objects?

A response object is a type-safe container that:

- **Structures Data**: Organizes response data in a consistent format
- **Handles Serialization**: Converts data to appropriate formats (JSON, XML, HTML)
- **Sets Content Types**: Specifies the response content type
- **Provides Type Safety**: Ensures compile-time type safety for responses

## Basic Response Object

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      created_at: @user.created_at.to_rfc3339
    }.to_json
  end
end
```

### Key Components

1. **Module Include**: `include Azu::Response`
2. **Initializer**: Accept data to be serialized
3. **Render Method**: Define how to serialize the data

## Built-in Response Types

Azu provides several built-in response types for common use cases:

### JSON Response

```crystal
struct JsonResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any))
  end

  def render
    @data.to_json
  end
end

# Usage in endpoint
def call : JsonResponse
  data = {
    "message" => "Success",
    "timestamp" => Time.utc.to_rfc3339
  }
  JsonResponse.new(data)
end
```

### HTML Response

```crystal
struct HtmlResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@template : String, @data : Hash(String, JSON::Any))
  end

  def render
    view @template, @data
  end
end

# Usage in endpoint
def call : HtmlResponse
  HtmlResponse.new("users/show.html", {
    "user" => @user,
    "title" => "User Profile"
  })
end
```

### Text Response

```crystal
struct TextResponse
  include Azu::Response

  def initialize(@text : String)
  end

  def render
    @text
  end
end

# Usage in endpoint
def call : TextResponse
  TextResponse.new("Hello, World!")
end
```

### Empty Response

```crystal
struct EmptyResponse
  include Azu::Response

  def initialize
  end

  def render
    ""
  end
end

# Usage for DELETE endpoints
def call : EmptyResponse
  delete_user
  EmptyResponse.new
end
```

## Custom Response Objects

Create custom response objects for your specific needs:

### Single Resource Response

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      age: @user.age,
      created_at: @user.created_at.to_rfc3339,
      updated_at: @user.updated_at.to_rfc3339
    }.to_json
  end
end
```

### Collection Response

```crystal
struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User), @pagination : Pagination? = nil)
  end

  def render
    {
      users: @users.map { |user| user_json(user) },
      count: @users.size,
      pagination: @pagination.try(&.to_json),
      timestamp: Time.utc.to_rfc3339
    }.to_json
  end

  private def user_json(user : User)
    {
      id: user.id,
      name: user.name,
      email: user.email,
      age: user.age,
      created_at: user.created_at.to_rfc3339
    }
  end
end
```

### Error Response

```crystal
struct ErrorResponse
  include Azu::Response

  def initialize(@message : String, @code : String? = nil, @details : Hash(String, JSON::Any)? = nil)
  end

  def render
    {
      error: {
        message: @message,
        code: @code,
        details: @details,
        timestamp: Time.utc.to_rfc3339
      }
    }.to_json
  end
end
```

## Content Type Handling

Set appropriate content types for your responses:

```crystal
struct ApiResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any), @content_type : String = "application/json")
  end

  def render
    # Set content type
    context.response.headers["Content-Type"] = @content_type

    case @content_type
    when "application/json"
      @data.to_json
    when "application/xml"
      to_xml(@data)
    when "text/plain"
      @data["message"].as_s
    else
      @data.to_json
    end
  end

  private def to_xml(data : Hash(String, JSON::Any))
    # XML serialization logic
    "<response>#{data.to_json}</response>"
  end
end
```

## Status Code Handling

Set appropriate HTTP status codes:

```crystal
struct StatusResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any), @status_code : Int32 = 200)
  end

  def render
    # Set status code
    status @status_code

    @data.to_json
  end
end

# Usage in endpoint
def call : StatusResponse
  user = create_user

  StatusResponse.new({
    "user" => user.to_json,
    "message" => "User created successfully"
  }, 201)
end
```

## Header Management

Set custom headers in your responses:

```crystal
struct HeaderResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any), @headers : Hash(String, String) = {} of String => String)
  end

  def render
    # Set custom headers
    @headers.each do |key, value|
      context.response.headers[key] = value
    end

    @data.to_json
  end
end

# Usage in endpoint
def call : HeaderResponse
  headers = {
    "X-Rate-Limit" => "1000",
    "X-Rate-Limit-Remaining" => "999",
    "Cache-Control" => "no-cache"
  }

  HeaderResponse.new({
    "data" => "response data"
  }, headers)
end
```

## Pagination Support

Handle paginated responses:

```crystal
struct PaginatedResponse
  include Azu::Response

  def initialize(@data : Array(JSON::Any), @page : Int32, @per_page : Int32, @total : Int32)
  end

  def render
    {
      data: @data,
      pagination: {
        page: @page,
        per_page: @per_page,
        total: @total,
        total_pages: (@total.to_f / @per_page).ceil.to_i,
        has_next: @page < (@total.to_f / @per_page).ceil,
        has_prev: @page > 1
      }
    }.to_json
  end
end
```

## Template Integration

Use templates for HTML responses:

```crystal
struct UserPageResponse
  include Azu::Response
  include Azu::Templates::Renderable

  def initialize(@user : User, @template : String = "users/show.html")
  end

  def render
    view @template, {
      "user" => @user,
      "title" => "User Profile",
      "timestamp" => Time.utc.to_rfc3339
    }
  end
end
```

## Streaming Responses

Handle large responses with streaming:

```crystal
struct StreamingResponse
  include Azu::Response

  def initialize(@data_stream : Iterator(String))
  end

  def render
    # Set streaming headers
    context.response.headers["Transfer-Encoding"] = "chunked"
    context.response.headers["Content-Type"] = "application/json"

    # Stream data
    @data_stream.each do |chunk|
      context.response << chunk
    end
  end
end
```

## File Downloads

Handle file downloads:

```crystal
struct FileDownloadResponse
  include Azu::Response

  def initialize(@file_path : String, @filename : String? = nil)
  end

  def render
    # Set download headers
    context.response.headers["Content-Disposition"] = "attachment; filename=\"#{@filename || File.basename(@file_path)}\""
    context.response.headers["Content-Type"] = MIME.from_filename(@file_path)

    # Read and send file
    File.read(@file_path)
  end
end
```

## Response Caching

Implement response caching:

```crystal
struct CachedResponse
  include Azu::Response

  def initialize(@data : Hash(String, JSON::Any), @cache_duration : Time::Span = 1.hour)
  end

  def render
    # Set cache headers
    expires_at = Time.utc + @cache_duration
    context.response.headers["Cache-Control"] = "public, max-age=#{@cache_duration.total_seconds.to_i}"
    context.response.headers["Expires"] = expires_at.to_rfc2822

    @data.to_json
  end
end
```

## Error Response Format

Standardize error responses:

```crystal
struct StandardErrorResponse
  include Azu::Response

  def initialize(@status : String, @title : String, @detail : String,
                 @field_errors : Hash(String, Array(String))? = nil,
                 @error_id : String? = nil)
  end

  def render
    {
      "Status" => @status,
      "Title" => @title,
      "Detail" => @detail,
      "FieldErrors" => @field_errors,
      "ErrorId" => @error_id,
      "Timestamp" => Time.utc.to_rfc3339
    }.to_json
  end
end
```

## Testing Response Objects

Test your response objects:

```crystal
require "spec"

describe UserResponse do
  it "renders user data correctly" do
    user = User.new("Alice", "alice@example.com", 30)
    response = UserResponse.new(user)

    json = JSON.parse(response.render)
    json["name"].should eq("Alice")
    json["email"].should eq("alice@example.com")
    json["age"].should eq(30)
  end

  it "includes timestamps" do
    user = User.new("Alice", "alice@example.com", 30)
    response = UserResponse.new(user)

    json = JSON.parse(response.render)
    json["created_at"].should_not be_nil
    json["updated_at"].should_not be_nil
  end
end
```

## Best Practices

### 1. Use Consistent Structure

```crystal
# Good: Consistent structure
struct UserResponse
  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      created_at: @user.created_at.to_rfc3339
    }.to_json
  end
end

# Avoid: Inconsistent structure
struct UserResponse
  def render
    {
      user_id: @user.id,  # Inconsistent naming
      full_name: @user.name,  # Different field name
      email_address: @user.email,  # Different field name
      created: @user.created_at.to_rfc3339  # Different field name
    }.to_json
  end
end
```

### 2. Handle Null Values

```crystal
struct UserResponse
  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      age: @user.age,  # Can be nil
      created_at: @user.created_at.to_rfc3339
    }.to_json
  end
end
```

### 3. Use Appropriate Content Types

```crystal
struct ApiResponse
  def render
    # Set content type
    context.response.headers["Content-Type"] = "application/json"

    @data.to_json
  end
end
```

### 4. Include Metadata

```crystal
struct ListResponse
  def render
    {
      data: @items.map(&.to_json),
      count: @items.size,
      timestamp: Time.utc.to_rfc3339,
      version: "1.0"
    }.to_json
  end
end
```

### 5. Handle Errors Gracefully

```crystal
struct SafeResponse
  def render
    begin
      @data.to_json
    rescue e
      {
        error: "Failed to serialize response",
        message: e.message
      }.to_json
    end
  end
end
```

## Performance Considerations

### 1. Lazy Loading

```crystal
struct LazyResponse
  def initialize(@user : User)
  end

  def render
    # Only load related data when needed
    user_data = {
      id: @user.id,
      name: @user.name,
      email: @user.email
    }

    # Load additional data only if requested
    if context.request.query_params["include"]?.try(&.includes?("posts"))
      user_data["posts"] = @user.posts.map(&.to_json)
    end

    user_data.to_json
  end
end
```

### 2. Caching

```crystal
struct CachedResponse
  def initialize(@data : Hash(String, JSON::Any))
  end

  def render
    # Set cache headers
    context.response.headers["Cache-Control"] = "public, max-age=3600"

    @data.to_json
  end
end
```

## Next Steps

Now that you understand response objects:

1. **[Endpoints](endpoints.md)** - Use response objects in your endpoints
2. **[Templates](../features/templates.md)** - Learn about template rendering
3. **[Caching](../features/caching.md)** - Implement response caching
4. **[Testing](../testing.md)** - Test your response objects
5. **[Performance](../advanced/performance.md)** - Optimize response performance

---

_Response objects provide the foundation for structured, type-safe output in Azu applications. With proper serialization, content type handling, and error management, they ensure consistent and reliable API responses._

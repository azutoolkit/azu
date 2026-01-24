# Response Reference

Response objects define how endpoint results are rendered to clients.

## Including Response

```crystal
struct MyResponse
  include Azu::Response

  def initialize(@data : MyData)
  end

  def render
    @data.to_json
  end
end
```

## Required Methods

### render

Return the response body as a string.

```crystal
def render : String
  {id: @user.id, name: @user.name}.to_json
end
```

**Returns:** `String`

## Built-in Response Types

### Azu::Response::Json

JSON response with automatic content type.

```crystal
struct MyEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Json)

  get "/data"

  def call
    json({message: "Hello", count: 42})
  end
end
```

### Azu::Response::Text

Plain text response.

```crystal
struct HealthEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/health"

  def call
    text "OK"
  end
end
```

### Azu::Response::Html

HTML response.

```crystal
struct PageEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Html)

  get "/page"

  def call
    html "<h1>Welcome</h1>"
  end
end
```

### Azu::Response::Empty

No content response (204).

```crystal
struct DeleteEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)

  delete "/items/:id"

  def call
    Item.find(params["id"]).destroy
    status 204
    Azu::Response::Empty.new
  end
end
```

## Error Responses

### Azu::Response::Error

Base class for error responses.

```crystal
class Azu::Response::Error < Exception
  getter status : Int32
  getter message : String

  def initialize(@message : String, @status : Int32 = 500)
  end
end
```

### Built-in Errors

| Class | Status | Usage |
|-------|--------|-------|
| `BadRequest` | 400 | Invalid request |
| `Unauthorized` | 401 | Authentication required |
| `Forbidden` | 403 | Access denied |
| `NotFound` | 404 | Resource not found |
| `MethodNotAllowed` | 405 | HTTP method not allowed |
| `Conflict` | 409 | Resource conflict |
| `UnprocessableEntity` | 422 | Validation failed |
| `TooManyRequests` | 429 | Rate limit exceeded |
| `InternalServerError` | 500 | Server error |
| `ServiceUnavailable` | 503 | Service unavailable |

### Using Error Responses

```crystal
def call
  user = User.find?(params["id"])
  raise Azu::Response::NotFound.new("/users/#{params["id"]}") unless user

  UserResponse.new(user)
end
```

### ValidationError

Special error for validation failures.

```crystal
raise Azu::Response::ValidationError.new([
  {field: "email", message: "is invalid"},
  {field: "name", message: "is required"}
])
```

## Custom Response Example

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
      created_at: @user.created_at.try(&.to_rfc3339)
    }.to_json
  end
end

struct UsersResponse
  include Azu::Response

  def initialize(
    @users : Array(User),
    @page : Int32,
    @total : Int64
  )
  end

  def render
    {
      data: @users.map { |u| serialize_user(u) },
      meta: {
        page: @page,
        total: @total
      }
    }.to_json
  end

  private def serialize_user(user : User)
    {id: user.id, name: user.name}
  end
end
```

## Response with Headers

Set custom headers in your endpoint:

```crystal
def call
  response.headers["X-Custom-Header"] = "value"
  response.headers["Cache-Control"] = "max-age=3600"

  MyResponse.new(data)
end
```

## Response with Status

Set custom status codes:

```crystal
def call
  status 201  # Created
  UserResponse.new(user)
end

def call
  status 202  # Accepted
  TaskResponse.new(task)
end
```

## Streaming Responses

For large responses:

```crystal
def call
  response.content_type = "application/json"
  response.headers["Transfer-Encoding"] = "chunked"

  response.print "["
  users.each_with_index do |user, i|
    response.print "," if i > 0
    response.print user.to_json
    response.flush
  end
  response.print "]"
end
```

## Content Negotiation

Return different formats based on Accept header:

```crystal
def call
  case accept_type
  when "application/json"
    json(data)
  when "text/html"
    html(render_html(data))
  when "text/plain"
    text(data.to_s)
  else
    json(data)
  end
end

private def accept_type
  headers["Accept"]?.try(&.split(",").first) || "application/json"
end
```

## See Also

- [Endpoint Reference](endpoint.md)
- [Request Reference](request.md)
- [Error Types Reference](../errors/error-types.md)

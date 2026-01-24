# How to Handle Parameters

This guide shows you how to extract and work with request parameters.

## Route Parameters

Define route parameters with a colon prefix:

```crystal
get "/users/:id"

def call
  id = params["id"]  # String
  id.to_i64          # Convert to Int64
end
```

### Multiple Route Parameters

```crystal
get "/users/:user_id/posts/:post_id"

def call
  user_id = params["user_id"].to_i64
  post_id = params["post_id"].to_i64
end
```

## Query Parameters

Access query string parameters:

```crystal
# URL: /search?q=crystal&page=2

get "/search"

def call
  query = params["q"]?            # "crystal" or nil
  page = params["page"]? || "1"   # "2" or default "1"
end
```

## Request Body (JSON)

Use request contracts to parse JSON bodies:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call
    name = create_user_request.name
    email = create_user_request.email
    age = create_user_request.age
  end
end
```

## Form Data

Handle form submissions:

```crystal
struct FormEndpoint
  include Azu::Endpoint(FormRequest, FormResponse)

  post "/submit"

  def call
    # Access form fields from request contract
    name = form_request.name
    email = form_request.email
  end
end
```

## File Uploads

Handle multipart file uploads:

```crystal
struct UploadRequest
  include Azu::Request

  getter file : HTTP::FormData::File
  getter description : String?

  def initialize(@file, @description = nil)
  end
end

struct UploadEndpoint
  include Azu::Endpoint(UploadRequest, UploadResponse)

  post "/upload"

  def call
    file = upload_request.file
    filename = file.filename
    content = file.content
    content_type = file.content_type
  end
end
```

## Headers

Access request headers:

```crystal
def call
  auth = headers["Authorization"]?
  user_agent = headers["User-Agent"]?
  accept = headers["Accept"]?
end
```

## Type Conversion

Convert string parameters to types:

```crystal
def call
  # String to integer
  id = params["id"].to_i64

  # String to boolean
  active = params["active"]? == "true"

  # String to enum
  status = Status.parse(params["status"]? || "pending")
end
```

## Default Values

Provide defaults for optional parameters:

```crystal
def call
  page = (params["page"]? || "1").to_i
  per_page = (params["per_page"]? || "20").to_i
  sort = params["sort"]? || "created_at"
  order = params["order"]? || "desc"
end
```

## See Also

- [Validate Requests](../validation/validate-requests.md)
- [Handle File Uploads](../file-handling/handle-file-uploads.md)

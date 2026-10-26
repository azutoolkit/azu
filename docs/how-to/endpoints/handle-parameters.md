# Handle parameters

This guide shows you how to extract and work with request parameters.

## Route Parameters

Define route parameters with a colon prefix:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id"

  def call : Azu::Response::Empty
    id = params["id"] # String
    id.to_i64         # Convert to Int64
    Azu::Response::Empty.new
  end
end
```

`params["id"]` raises `KeyError` when the parameter is missing; `params["id"]?` returns `nil` instead.

### Multiple Route Parameters

```crystal
struct ShowPostEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:user_id/posts/:post_id"

  def call : Azu::Response::Empty
    user_id = params["user_id"].to_i64
    post_id = params["post_id"].to_i64
    Azu::Response::Empty.new
  end
end
```

## Query Parameters

Access query string parameters:

```crystal
# URL: /search?q=crystal&page=2

struct SearchEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/search"

  def call : Azu::Response::Empty
    query = params["q"]?          # "crystal" or nil
    page = params["page"]? || "1" # "2" or default "1"
    Azu::Response::Empty.new
  end
end
```

`params` looks in the form body, then the route parameters, then the query string. Use `params.query`,
`params.path` and `params.form` to read one source only, and `params.fetch_all("tag")` for a repeated key.

## Request Body (JSON)

Use request contracts to parse JSON bodies. The contract is parsed once per call, and a request that breaks its
validations is answered with `422` before `call` runs:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true
end

struct CreateUserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, CreateUserResponse)

  post "/users"

  def call : CreateUserResponse
    name = create_user_request.name
    email = create_user_request.email
    age = create_user_request.age
    CreateUserResponse.new(name)
  end
end
```

## Form Data

The same contract reads URL-encoded form submissions. Fields are matched by name, and the query string is part
of the same input:

```crystal
struct FormRequest
  include Azu::Request

  getter name : String
  getter email : String

  def initialize(@name = "", @email = "")
  end
end

struct FormEndpoint
  include Azu::Endpoint(FormRequest, Azu::Response::Empty)

  post "/submit"

  def call : Azu::Response::Empty
    # Access form fields from request contract
    name = form_request.name
    email = form_request.email
    Azu::Response::Empty.new
  end
end
```

## File Uploads

Uploaded files are not part of the contract. Read them from `params.files`:

```crystal
struct UploadEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  post "/upload"

  def call : Azu::Response::Empty
    upload = params.files["file"]
    filename = upload.filename                  # String?
    size = upload.size                          # UInt64?
    content_type = upload.headers["Content-Type"]?
    contents = upload.file.gets_to_end          # the temp file holding the upload
    Azu::Response::Empty.new
  end
end
```

## Headers

Access request headers:

```crystal
struct HeadersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/headers"

  def call : Azu::Response::Empty
    auth = header["Authorization"]?
    user_agent = header["User-Agent"]?
    accept = header["Accept"]?
    Azu::Response::Empty.new
  end
end
```

## Type Conversion

Convert string parameters to types. Use the `?` variants when the input is not trusted: `to_i64` raises on text
that is not a number, which would be answered with a 500.

```crystal
enum Status
  Pending
  Active
end

struct ConvertEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/convert/:id"

  def call : Azu::Response::Empty
    # String to integer
    id = params["id"].to_i64?

    # String to boolean
    active = params["active"]? == "true"

    # String to enum
    status = Status.parse?(params["status"]? || "pending") || Status::Pending

    Azu::Response::Empty.new
  end
end
```

A request contract does the conversion for you: a field typed `Int32` or `Bool` is parsed from the form or JSON input,
and input that cannot be converted is answered with a `400`.

## Default Values

Provide defaults for optional parameters:

```crystal
struct ListEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/list"

  def call : Azu::Response::Empty
    page = (params["page"]? || "1").to_i
    per_page = (params["per_page"]? || "20").to_i
    sort = params["sort"]? || "created_at"
    order = params["order"]? || "desc"
    Azu::Response::Empty.new
  end
end
```

## See Also

- [Validate Requests](../validation/validate-requests.md)
- [Handle File Uploads](../file-handling/handle-file-uploads.md)

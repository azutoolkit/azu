# How to Create an Endpoint

This guide shows you how to create type-safe HTTP endpoints in Azu.

## Basic Endpoint

Create an endpoint by including `Azu::Endpoint` with request and response types:

```crystal
struct HelloEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)

  get "/"

  def call
    text "Hello, World!"
  end
end
```

## Endpoint with JSON Response

```crystal
struct UserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64
    user = User.find(user_id)

    if user
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {id: @user.id, name: @user.name, email: @user.email}.to_json
  end
end
```

## HTTP Method Macros

Use macros to declare the HTTP method:

```crystal
get "/path"      # GET request
post "/path"     # POST request
put "/path"      # PUT request
patch "/path"    # PATCH request
delete "/path"   # DELETE request
```

## Accessing Request Data

### Route Parameters

```crystal
get "/users/:id/posts/:post_id"

def call
  user_id = params["id"]
  post_id = params["post_id"]
end
```

### Query Parameters

```crystal
get "/search"

def call
  query = params["q"]?        # Optional
  page = params["page"]? || "1"
end
```

### Request Headers

```crystal
def call
  auth_header = headers["Authorization"]?
  content_type = headers["Content-Type"]?
end
```

## Setting Response Status

```crystal
def call
  status 201  # Created
  UserResponse.new(user)
end
```

## Registering Endpoints

Add endpoints to your application:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  HelloEndpoint.new,
  UserEndpoint.new,
]
```

## See Also

- [Handle Parameters](handle-parameters.md)
- [Return Different Formats](return-different-formats.md)

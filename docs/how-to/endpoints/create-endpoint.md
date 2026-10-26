# Create an endpoint

Create type-safe HTTP endpoints in Azu.

## Basic Endpoint

Create an endpoint by including `Azu::Endpoint` with request and response types. `Azu::Request` stands for
"no request body to validate":

```crystal
struct HelloResponse
  include Azu::Response

  def initialize(@message : String)
  end

  def render
    @message
  end
end

struct HelloEndpoint
  include Azu::Endpoint(Azu::Request, HelloResponse)

  get "/"

  def call : HelloResponse
    content_type "text/plain"
    HelloResponse.new("Hello, World!")
  end
end
```

## Endpoint with JSON Response

```crystal
struct User
  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email)
  end

  def self.find?(id : Int64) : User?
    new(id, "Ada", "ada@example.com") if id == 1
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

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find?(user_id)
      content_type "application/json"
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end
```

## HTTP Method Macros

Use macros to declare the HTTP method. Each endpoint declares one route:

```crystal
struct EmptyResponse
  include Azu::Response

  def render
  end
end

struct ListPosts
  include Azu::Endpoint(Azu::Request, EmptyResponse)

  get "/posts" # GET request

  def call : EmptyResponse
    EmptyResponse.new
  end
end

struct CreatePost
  include Azu::Endpoint(Azu::Request, EmptyResponse)

  post "/posts" # POST request

  def call : EmptyResponse
    EmptyResponse.new
  end
end

struct ReplacePost
  include Azu::Endpoint(Azu::Request, EmptyResponse)

  put "/posts/:id" # PUT request

  def call : EmptyResponse
    EmptyResponse.new
  end
end

struct UpdatePost
  include Azu::Endpoint(Azu::Request, EmptyResponse)

  patch "/posts/:id" # PATCH request

  def call : EmptyResponse
    EmptyResponse.new
  end
end

struct DeletePost
  include Azu::Endpoint(Azu::Request, EmptyResponse)

  delete "/posts/:id" # DELETE request

  def call : EmptyResponse
    EmptyResponse.new
  end
end
```

## Accessing Request Data

### Route Parameters

```crystal
struct PostEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/users/:id/posts/:post_id"

  def call : Azu::Response::Empty
    user_id = params["id"]
    post_id = params["post_id"]
    Azu::Response::Empty.new
  end
end
```

### Query Parameters

```crystal
struct SearchEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/search"

  def call : Azu::Response::Empty
    query = params["q"]?          # Optional
    page = params["page"]? || "1"
    Azu::Response::Empty.new
  end
end
```

### Request Headers

```crystal
struct HeadersEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  get "/headers"

  def call : Azu::Response::Empty
    auth_header = header["Authorization"]?
    content_type = header["Content-Type"]?
    Azu::Response::Empty.new
  end
end
```

## Setting Response Status

```crystal
struct CreatedResponse
  include Azu::Response

  def render
    {created: true}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(Azu::Request, CreatedResponse)

  post "/users"

  def call : CreatedResponse
    status 201 # Created
    CreatedResponse.new
  end
end
```

## Registering Endpoints

A verb macro (`get`, `post`, ...) registers the endpoint when the type is defined, so there is nothing to add to the
handler chain: endpoints are reached through the router, and `start` serves them.

```crystal
module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new,
] of HTTP::Handler
```

To keep the routes of an app in one place instead, declare them on the app. The endpoint then needs no verb macro:

```crystal
struct PingEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  def call : Azu::Response::Empty
    Azu::Response::Empty.new
  end
end

app = Azu::App.new
app.routes do
  get "/ping", PingEndpoint
  scope "/api" do
    get "/ping", PingEndpoint
  end
end
```

## See Also

- [Handle Parameters](handle-parameters.md)
- [Return Different Formats](return-different-formats.md)

# Building a User API

This tutorial walks you through building a complete RESTful API for user management with type-safe endpoints, validation, and proper error handling.

## What You'll Build

By the end of this tutorial, you'll have:

- CRUD endpoints for user management
- Request validation with error messages
- Type-safe request and response contracts
- Proper error handling and status codes

## Prerequisites

- Completed the [Getting Started](getting-started.md) tutorial
- Azu installed and working

## Step 1: Project Setup

Create a new project:

```bash
crystal init app user_api
cd user_api
```

Update `shard.yml`:

```yaml
name: user_api
version: 0.1.0

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.28

crystal: >= 0.35.0
license: MIT
```

Install dependencies:

```bash
shards install
```

Create the project structure:

```bash
mkdir -p src/{models,requests,responses,endpoints}
```

## Step 2: Create the User Model

Create `src/models/user.cr`:

```crystal
class User
  property id : Int64
  property name : String
  property email : String
  property age : Int32?
  property created_at : Time
  property updated_at : Time

  @@next_id = 1_i64
  @@users = [] of User

  def initialize(@name : String, @email : String, @age : Int32? = nil)
    @id = @@next_id
    @@next_id += 1
    @created_at = Time.utc
    @updated_at = Time.utc
    @@users << self
  end

  def self.all : Array(User)
    @@users.dup
  end

  def self.find(id : Int64) : User?
    @@users.find { |u| u.id == id }
  end

  def self.find_by_email(email : String) : User?
    @@users.find { |u| u.email == email }
  end

  def update(name : String? = nil, email : String? = nil, age : Int32? = nil)
    @name = name if name
    @email = email if email
    @age = age if age
    @updated_at = Time.utc
  end

  def delete
    @@users.delete(self)
  end

  def to_json(json : JSON::Builder)
    json.object do
      json.field "id", @id
      json.field "name", @name
      json.field "email", @email
      json.field "age", @age
      json.field "created_at", @created_at.to_rfc3339
      json.field "updated_at", @updated_at.to_rfc3339
    end
  end
end
```

> **Note:** This tutorial uses in-memory storage for simplicity. See [Working with Databases](working-with-databases.md) for production database integration.

## Step 3: Create Request Contracts

Request contracts validate incoming data automatically.

Create `src/requests/create_user_request.cr`:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true, length: {min: 2, max: 50},
    message: "Name must be between 2 and 50 characters"

  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i,
    message: "Email must be a valid email address"

  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true,
    message: "Age must be between 1 and 150"
end
```

Create `src/requests/update_user_request.cr`:

```crystal
struct UpdateUserRequest
  include Azu::Request

  getter name : String?
  getter email : String?
  getter age : Int32?

  def initialize(@name = nil, @email = nil, @age = nil)
  end

  validate name, length: {min: 2, max: 50}, allow_nil: true,
    message: "Name must be between 2 and 50 characters"

  validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, allow_nil: true,
    message: "Email must be a valid email address"

  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true,
    message: "Age must be between 1 and 150"
end
```

## Step 4: Create Response Objects

Response objects define your API's output format.

Create `src/responses/user_response.cr`:

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

Create `src/responses/users_list_response.cr`:

```crystal
struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    {
      users: @users.map { |user| user_json(user) },
      count: @users.size,
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

## Step 5: Create Endpoints

Now create the CRUD endpoints.

Create `src/endpoints/create_user_endpoint.cr`:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Validate request
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check for duplicate email
    if User.find_by_email(create_user_request.email)
      raise Azu::Response::ValidationError.new(
        {"email" => ["Email is already taken"]}
      )
    end

    # Create user
    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    status 201
    UserResponse.new(user)
  end
end
```

Create `src/endpoints/list_users_endpoint.cr`:

```crystal
struct ListUsersEndpoint
  include Azu::Endpoint(EmptyRequest, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    users = User.all
    UsersListResponse.new(users)
  end
end
```

Create `src/endpoints/show_user_endpoint.cr`:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find(user_id)
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end
```

Create `src/endpoints/update_user_endpoint.cr`:

```crystal
struct UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)

  put "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    unless user = User.find(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    # Validate request
    unless update_user_request.valid?
      raise Azu::Response::ValidationError.new(
        update_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check for duplicate email if updating
    if email = update_user_request.email
      if existing = User.find_by_email(email)
        unless existing.id == user_id
          raise Azu::Response::ValidationError.new(
            {"email" => ["Email is already taken"]}
          )
        end
      end
    end

    # Update user
    user.update(
      name: update_user_request.name,
      email: update_user_request.email,
      age: update_user_request.age
    )

    UserResponse.new(user)
  end
end
```

Create `src/endpoints/delete_user_endpoint.cr`:

```crystal
struct DeleteUserEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    user_id = params["id"].to_i64

    unless user = User.find(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    user.delete
    status 204
    Azu::Response::Empty.new
  end
end
```

## Step 6: Create the Main Application

Create `src/user_api.cr`:

```crystal
require "azu"

# Load application files
require "./models/*"
require "./requests/*"
require "./responses/*"
require "./endpoints/*"

module UserAPI
  include Azu

  configure do
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")
    log.level = Log::Severity::DEBUG
  end
end

# Start the application
UserAPI.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  ListUsersEndpoint.new,
  ShowUserEndpoint.new,
  CreateUserEndpoint.new,
  UpdateUserEndpoint.new,
  DeleteUserEndpoint.new,
]
```

## Step 7: Run and Test

Start the server:

```bash
crystal run src/user_api.cr
```

### Create a User

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Smith", "email": "alice@example.com", "age": 30}'
```

Response:
```json
{
  "id": 1,
  "name": "Alice Smith",
  "email": "alice@example.com",
  "age": 30,
  "created_at": "2026-01-24T15:30:45Z",
  "updated_at": "2026-01-24T15:30:45Z"
}
```

### List Users

```bash
curl http://localhost:4000/users
```

### Get a User

```bash
curl http://localhost:4000/users/1
```

### Update a User

```bash
curl -X PUT http://localhost:4000/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Johnson", "age": 31}'
```

### Delete a User

```bash
curl -X DELETE http://localhost:4000/users/1
```

### Test Validation

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{}'
```

Response:
```json
{
  "Status": "Unprocessable Entity",
  "Title": "Validation Error",
  "FieldErrors": {
    "name": ["Name must be between 2 and 50 characters"],
    "email": ["Email must be a valid email address"]
  }
}
```

## Key Concepts Learned

### Type-Safe Contracts

Every endpoint declares exactly what it accepts and returns:
```crystal
include Azu::Endpoint(CreateUserRequest, UserResponse)
```

### Automatic Validation

Request contracts validate data before your handler runs:
```crystal
validate name, presence: true, length: {min: 2, max: 50}
```

### Structured Error Responses

Validation errors return consistent, structured JSON responses with proper HTTP status codes.

### Route Parameters

Access URL segments via the `params` hash:
```crystal
get "/users/:id"
# params["id"] contains the value
```

## Project Structure

```
user_api/
├── shard.yml
├── src/
│   ├── user_api.cr           # Main application
│   ├── models/
│   │   └── user.cr           # User model
│   ├── requests/
│   │   ├── create_user_request.cr
│   │   └── update_user_request.cr
│   ├── responses/
│   │   ├── user_response.cr
│   │   └── users_list_response.cr
│   └── endpoints/
│       ├── create_user_endpoint.cr
│       ├── list_users_endpoint.cr
│       ├── show_user_endpoint.cr
│       ├── update_user_endpoint.cr
│       └── delete_user_endpoint.cr
└── spec/
```

## Next Steps

You've built a complete REST API. Continue learning with:

- [Adding WebSockets](adding-websockets.md) - Add real-time notifications
- [Working with Databases](working-with-databases.md) - Replace in-memory storage with PostgreSQL
- [Testing Your App](testing-your-app.md) - Write tests for your endpoints

---

**Your API is ready!** You now understand how to build type-safe, validated REST APIs with Azu.

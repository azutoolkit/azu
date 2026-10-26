# Building a user API

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
    version: ~> 0.5.119

crystal: ">= 1.19.1"
license: MIT
```

Install dependencies:

```bash
shards install
```

This tutorial keeps everything in one file, `src/user_api.cr`, built up step by step. Each step adds to the file; the
steps that stand alone compile on their own, and the last one needs the types of the earlier ones.

## Step 2: The Model and the Responses

Open `src/user_api.cr`. The model keeps users in memory so the tutorial needs no database. Responses turn data into
the body that is sent:

```crystal
require "azu"

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

  def update(name : String? = nil, email : String? = nil, age : Int32? = nil) : Nil
    @name = name if name
    @email = email if email
    @age = age if age
    @updated_at = Time.utc
  end

  def delete : Nil
    @@users.delete(self)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id:         @user.id,
      name:       @user.name,
      email:      @user.email,
      age:        @user.age,
      created_at: @user.created_at.to_rfc3339,
      updated_at: @user.updated_at.to_rfc3339,
    }.to_json
  end
end

struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    {
      users: @users.map { |user| {id: user.id, name: user.name, email: user.email, age: user.age} },
      count: @users.size,
    }.to_json
  end
end
```

> **Note:** This tutorial uses in-memory storage for simplicity (a class variable is shared by every request, so it
> is only suitable for a single process). See [Working with Databases](working-with-databases.md) for a database.

## Step 3: Request Contracts

A request contract declares the fields a request may carry and the rules they must satisfy. An endpoint whose
contract has rules never runs for a request that breaks them: the client gets a `422` with the failing fields.

Fields need default values (`= ""`) so that a body with a missing field becomes a validation error rather than
a parse error. `validate` rules check required fields; for optional fields (`Int32?`) write a `Schema::Validator`
and attach it with `use`. Add to the file:

```crystal
require "azu"

EMAIL = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

# Rules for fields that may be missing: only the ones that are present are checked.
module UserRules
  def self.check(name : String?, email : String?, age : Int32?) : Array(Schema::Error)
    errors = [] of Schema::Error
    errors << Schema::Error.new(:name, "Name must be between 2 and 50 characters") if name && !(2..50).includes?(name.size)
    errors << Schema::Error.new(:email, "Email must be a valid email address") if email && !EMAIL.matches?(email)
    errors << Schema::Error.new(:age, "Age must be between 1 and 150") if age && !(1..150).includes?(age)
    errors
  end
end

class CreateUserValidator < Schema::Validator
  def initialize(@record : CreateUserRequest)
  end

  def valid? : Array(Schema::Error)
    UserRules.check(nil, nil, @record.age)
  end
end

class UpdateUserValidator < Schema::Validator
  def initialize(@record : UpdateUserRequest)
  end

  def valid? : Array(Schema::Error)
    UserRules.check(@record.name, @record.email, @record.age)
  end
end

struct CreateUserRequest
  include Azu::Request

  getter name : String = ""
  getter email : String = ""
  getter age : Int32? = nil

  validate name, size: 2..50, message: "Name must be between 2 and 50 characters"
  validate email, match: EMAIL, message: "Email must be a valid email address"
  use CreateUserValidator
end

struct UpdateUserRequest
  include Azu::Request

  getter name : String? = nil
  getter email : String? = nil
  getter age : Int32? = nil

  use UpdateUserValidator
end
```

`size: 2..50` is a `Range` rule for the length of a string, `match:` takes a regular expression, and `message:`
replaces the default text. See [Validate Requests](../how-to/validation/validate-requests.md) for all rules.

## Step 4: Endpoints

Add the five endpoints to the file. Every endpoint is a `struct`, so each request gets its own instance:

<!-- skip -->
```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    content_type "application/json"
    if User.find_by_email(create_user_request.email)
      raise Azu::Response::ValidationError.new("email", "Email is already taken")
    end

    user = User.new(create_user_request.name, create_user_request.email, create_user_request.age)
    status 201
    UserResponse.new(user)
  end
end

struct ListUsersEndpoint
  include Azu::Endpoint(Azu::Request, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    content_type "application/json"
    UsersListResponse.new(User.all)
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    content_type "application/json"
    user_id = params["id"].to_i64
    user = User.find(user_id) || raise Azu::Response::NotFound.new("/users/#{user_id}")
    UserResponse.new(user)
  end
end

struct UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)

  put "/users/:id"

  def call : UserResponse
    content_type "application/json"
    user_id = params["id"].to_i64
    user = User.find(user_id) || raise Azu::Response::NotFound.new("/users/#{user_id}")

    if email = update_user_request.email
      if (existing = User.find_by_email(email)) && existing.id != user_id
        raise Azu::Response::ValidationError.new("email", "Email is already taken")
      end
    end

    user.update(update_user_request.name, update_user_request.email, update_user_request.age)
    UserResponse.new(user)
  end
end

struct DeleteUserEndpoint
  include Azu::Endpoint(Azu::Request, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    user_id = params["id"].to_i64
    user = User.find(user_id) || raise Azu::Response::NotFound.new("/users/#{user_id}")
    user.delete
    status 204
    Azu::Response::Empty.new
  end
end
```

`create_user_request` is the contract parsed from the body (JSON, form or query string), named after the request
type. `params["id"]` reads the `:id` segment of the path. `status 201` and `status 204` set the response code.
Raising an `Azu::Response::Error` such as `NotFound` or `ValidationError` ends the request; `Azu::Handler::Rescuer`
turns it into the response, in the format the `Accept` header asks for.

## Step 5: Start the Application

Add to the end of the file:

```crystal
require "azu"

module UserAPI
  include Azu
end

Azu.setup_logging
UserAPI.start
```

`UserAPI.start` without arguments serves the default stack: `RequestId`, `Logger`, `Rescuer`, `SecurityHeaders` and
`Static`, with the router (and so the endpoints, which register themselves) last. `Azu.setup_logging` turns on Azu's
log format; requiring `azu` does not touch `Log`.

Azu reads the address from the environment: `PORT` (4000 by default) and `HOST` (`127.0.0.1` in development,
`0.0.0.0` in other environments). In a container, set `HOST=0.0.0.0`.

## Step 6: Run and Test

Start the server:

```bash
crystal run src/user_api.cr
```

Send `Accept: application/json` to get JSON error bodies (without an `Accept` header, or with curl's default `*/*`,
error bodies are plain text).

### Create a User

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"name": "Alice Smith", "email": "alice@example.com", "age": 30}'
```

Response (`201`):

```json
{"id":1,"name":"Alice Smith","email":"alice@example.com","age":30,"created_at":"2026-10-23T18:02:44Z","updated_at":"2026-10-23T18:02:44Z"}
```

### List, Show, Update and Delete

```bash
curl -H "Accept: application/json" http://localhost:4000/users
curl -H "Accept: application/json" http://localhost:4000/users/1
curl -X PUT http://localhost:4000/users/1 \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"name": "Alice Johnson", "age": 31}'
curl -X DELETE http://localhost:4000/users/1
```

Deleting answers `204`; asking for a user that does not exist answers `404`.

### Test Validation

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"name": "A", "email": "bad"}'
```

Response (`422`, a problem document):

```json
{
  "type": "about:blank",
  "title": "Validation Error",
  "status": 422,
  "detail": "The request could not be processed due to validation errors.",
  "errors": {
    "name": ["Name must be between 2 and 50 characters"],
    "email": ["Email must be a valid email address"]
  },
  "instance": "/users"
}
```

A body that cannot be parsed into the contract at all (for example `"age": "x"`) answers `400`. Registering a second
user with the same email raises `ValidationError` from the endpoint and also answers `422`.

## Project Structure

```text
user_api/
├── shard.yml
├── src/
│   └── user_api.cr           # model, contracts, responses, endpoints, start
└── spec/
```

As the app grows, split the file by layer (`models/`, `requests/`, `responses/`, `endpoints/`) and `require` them
from `src/user_api.cr`.

## Next Steps

- [Adding WebSockets](adding-websockets.md) - Add real-time notifications
- [Working with Databases](working-with-databases.md) - Replace in-memory storage with PostgreSQL
- [Testing Your App](testing-your-app.md) - Write tests for your endpoints
- [Deploying to Production](deploying-to-production.md)

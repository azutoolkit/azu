# Type Safety in Azu

This document explains how Azu leverages Crystal's type system to catch errors at compile time rather than runtime.

## The Problem with Dynamic Types

In dynamically typed frameworks, common errors only appear at runtime:

```ruby
# Ruby/Rails - These errors happen at runtime
def create
  user = User.create(params[:user])
  render json: user.to_josn  # Typo not caught until runtime
end
```

You might deploy this code and only discover the bug when a user hits it.

## Crystal's Static Typing

Crystal catches errors at compile time:

```text
# This won't compile - typo caught immediately
user.to_josn  # Error: undefined method 'to_josn' for User

# Correct
user.to_json
```

## Type-Safe Endpoints

Azu uses generics to enforce types:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String

  def initialize(@name = "")
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@name : String)
  end

  def render
    {name: @name}.to_json
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑ Input type       ↑ Output type

  post "/users"

  def call : UserResponse # ← Must return this type
    UserResponse.new(create_user_request.name)
  end
end
```

The compiler ensures:
- `call` returns `UserResponse`
- All code paths return the correct type
- The request object has the expected shape

### What Happens If You Return Wrong Type

This endpoint does not compile, which is the point:

<!-- skip -->
```crystal
def call : UserResponse
  if user = find_user
    UserResponse.new(user)
  else
    "Not found" # Error: expected UserResponse, got String
  end
end
```

This error is caught at compile time, not after deployment.

## Type-Safe Requests

Request contracts define expected input:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String  # Required string
  getter email : String # Required string
  getter age : Int32?   # Optional integer

  def initialize(@name = "", @email = "", @age = nil)
  end
end
```

Benefits:
- Clear documentation of expected input
- Automatic parsing into correct types: input that cannot be converted is answered with `400`
- Validation runs before your code

### Accessing Request Data

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter age : Int32?

  def initialize(@name = "", @age = nil)
  end
end

struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, Azu::Response::Empty)

  post "/users"

  def call : Azu::Response::Empty
    # Type is known - no nil checks needed
    name = create_user_request.name # String, not String?

    # Optional fields are nil-able
    if age = create_user_request.age
      age + 1 # age is an Int32 here
    end

    Azu::Response::Empty.new
  end
end
```

## Type-Safe Responses

Responses define output shape:

```crystal
struct User
  getter id : Int64
  getter name : String
  getter email : String

  def initialize(@id, @name, @email)
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id:    @user.id,    # Int64
      name:  @user.name,  # String
      email: @user.email, # String
    }.to_json
  end
end
```

The compiler verifies:
- All fields exist on `User`
- Types are correct for JSON serialization

## Type-Safe Parameters

Route parameters are always strings, but conversion is explicit:

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@id : Int64)
  end

  def render
    {id: @id}.to_json
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # params["id"] is String
    id = params["id"].to_i64 # Explicit conversion to Int64

    UserResponse.new(id)
  end
end
```

## Nil Safety

Crystal's nil-safety prevents null pointer errors:

```crystal
struct User
  getter name : String

  def initialize(@name)
  end

  def self.find?(id : String) : User?
    new("Ada") if id == "1"
  end
end

struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    @user.name
  end
end

struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user = User.find?(params["id"])

    # user is User? (might be nil), so `user.name` here would not compile:
    # undefined method 'name' for Nil

    # Must handle nil case
    if user
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{params["id"]}")
    end
  end
end
```

## Union Types

Handle multiple cases explicitly. When an endpoint answers with more than one response type, declare the union as its
response type:

```crystal
struct CreateResponse
  include Azu::Response

  def render
    {created: true}.to_json
  end
end

struct ItemEndpoint
  include Azu::Endpoint(Azu::Request, CreateResponse | Azu::Response::Empty)

  post "/items/:action"

  def call : CreateResponse | Azu::Response::Empty
    case params["action"]
    when "create"
      CreateResponse.new
    when "delete"
      status 204
      Azu::Response::Empty.new
    else
      raise Azu::Response::BadRequest.new("Unknown action")
    end
  end
end
```

## Generic Helpers

Create reusable, type-safe helpers with generics:

```crystal
struct Profile
  include JSON::Serializable

  getter name : String

  def initialize(@name)
  end
end

class JsonCache(T)
  def initialize(@ttl : Time::Span = 5.minutes)
  end

  # Returns a T whether it comes from the cache or from the block
  def fetch(key : String, & : -> T) : T
    if cached = Azu.cache.get(key)
      return T.from_json(cached)
    end

    value = yield
    Azu.cache.set(key, value.to_json, ttl: @ttl)
    value
  end
end

struct ProfileResponse
  include Azu::Response

  def initialize(@profile : Profile)
  end

  def render
    @profile.to_json
  end
end

struct ProfileEndpoint
  include Azu::Endpoint(Azu::Request, ProfileResponse)

  get "/profile"

  def call : ProfileResponse
    profile = JsonCache(Profile).new.fetch("profile") { Profile.new("Ada") }
    ProfileResponse.new(profile)
  end
end
```

## Error Messages

Crystal's error messages help identify issues:

```text
Error: no overload matches 'User.find' with types (String)

Overloads are:
 - User.find(id : Int64)
```

## Trade-offs

### Advantages

- Catch bugs before deployment
- Self-documenting code
- Better IDE support
- Refactoring confidence

### Considerations

- More upfront type declarations
- Learning curve for dynamic language developers
- Some patterns require more verbose code

## Best Practices

1. **Be explicit about types**
   ```text
   def call : UserResponse  # Always specify return type
   ```

2. **Use meaningful type aliases**
   ```text
   alias UserId = Int64
   alias Email = String
   ```

3. **Handle all cases**

   `case ... in` on an enum is checked for exhaustiveness: leaving out a member is a compile error.

   ```crystal
   enum Status
     Pending
     Active
     Archived
   end

   def label(status : Status) : String
     case status
     in .pending?
       "Pending"
     in .active?
       "Active"
     in .archived?
       "Archived"
     end
   end
   ```

4. **Leverage union types for flexibility**
   ```text
   def find(id : Int64 | String)
     # Accept either type
   end
   ```

## See Also

- [Why Type Safety](../design-decisions/why-type-safety.md)
- [Request Reference](../../reference/api/request.md)
- [Response Reference](../../reference/api/response.md)

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

```crystal
# This won't compile - typo caught immediately
user.to_josn  # Error: undefined method 'to_josn' for User

# Correct
user.to_json
```

## Type-Safe Endpoints

Azu uses generics to enforce types:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑ Input type       ↑ Output type

  def call : UserResponse  # ← Must return this type
    # ...
  end
end
```

The compiler ensures:
- `call` returns `UserResponse`
- All code paths return the correct type
- The request object has the expected shape

### What Happens If You Return Wrong Type

```crystal
def call : UserResponse
  if user = find_user
    UserResponse.new(user)
  else
    "Not found"  # Error: expected UserResponse, got String
  end
end
```

This error is caught at compile time, not after deployment.

## Type-Safe Requests

Request contracts define expected input:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String      # Required string
  getter email : String     # Required string
  getter age : Int32?       # Optional integer
end
```

Benefits:
- Clear documentation of expected input
- Automatic parsing into correct types
- Validation runs before your code

### Accessing Request Data

```crystal
def call : UserResponse
  # Type is known - no nil checks needed
  name = create_user_request.name  # String, not String?

  # Optional fields are nil-able
  if age = create_user_request.age
    validate_age(age)
  end

  # ...
end
```

## Type-Safe Responses

Responses define output shape:

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,        # Int64
      name: @user.name,    # String
      email: @user.email   # String
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
get "/users/:id"

def call : UserResponse
  # params["id"] is String
  id = params["id"].to_i64  # Explicit conversion to Int64

  user = User.find(id)
  UserResponse.new(user)
end
```

## Nil Safety

Crystal's nil-safety prevents null pointer errors:

```crystal
def call : UserResponse
  user = User.find?(params["id"])

  # user is User? (might be nil)
  user.name  # Error: undefined method 'name' for Nil

  # Must handle nil case
  if user
    UserResponse.new(user)
  else
    raise Azu::Response::NotFound.new("/users/#{params["id"]}")
  end
end
```

## Union Types

Handle multiple cases explicitly:

```crystal
def call : Azu::Response
  case action
  when "create"
    CreateResponse.new(create_item)
  when "delete"
    status 204
    Azu::Response::Empty.new
  else
    raise Azu::Response::BadRequest.new("Unknown action")
  end
end
```

## Generic Handlers

Create reusable, type-safe handlers:

```crystal
class CacheHandler(T) < Azu::Handler::Base
  def call(context)
    key = cache_key(context)

    if cached = Azu.cache.get(key)
      return T.from_json(cached)
    end

    call_next(context)
  end
end
```

## Error Messages

Crystal's error messages help identify issues:

```
Error: no overload matches 'User.find' with types (String)

Overloads are:
 - User.find(id : Int64)

Did you mean to convert the argument?
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
   ```crystal
   def call : UserResponse  # Always specify return type
   ```

2. **Use meaningful type aliases**
   ```crystal
   alias UserId = Int64
   alias Email = String
   ```

3. **Handle all cases**
   ```crystal
   case status
   when .pending?
     # ...
   when .active?
     # ...
   when .archived?
     # ...
   end
   # Compiler warns if case not exhaustive
   ```

4. **Leverage union types for flexibility**
   ```crystal
   def find(id : Int64 | String)
     # Accept either type
   end
   ```

## See Also

- [Why Type Safety](../design-decisions/why-type-safety.md)
- [Request Reference](../../reference/api/request.md)
- [Response Reference](../../reference/api/response.md)

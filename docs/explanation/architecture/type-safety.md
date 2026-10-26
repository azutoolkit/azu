# Type safety

Azu uses Crystal's type system so that the shape of every request, response and endpoint is checked when the
application compiles: a typo, a missing field or an unhandled `nil` stops the build instead of reaching a user. This
page explains where Azu puts types, what the compiler checks with them, and what they cost.

## Errors at compile time

In a dynamically typed framework, common errors only appear at runtime:

```ruby
# Ruby/Rails: the typo is found when a user calls this action
def show
  user = User.find(params[:id])
  render json: user.to_josn
end
```

Such an error happens in production, affects a real user, needs monitoring to be noticed and a hotfix to be resolved.
Crystal resolves every method call when it compiles, so the same typo stops the build:

```text
# Does not compile: the typo is caught immediately
user.to_josn  # Error: undefined method 'to_josn' for User

# Correct
user.to_json
```

## Request contracts

A request contract declares the input an endpoint accepts, field by field:

<!-- prelude -->
```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String  # required
  getter email : String # required
  getter age : Int32?   # optional

  def initialize(@name = "", @email = "", @age = nil)
  end

  validate name, presence: true
  validate email, presence: true, match: /@/
end
```

The contract is the documentation of the expected input, and the compiler holds the code to it: every use of `name`
is a `String`, and `age` is checked for `nil` before use. At runtime Azu parses the request into those types and
answers `400` for input that cannot be converted, then runs the `validate` rules and answers `422` for input that
breaks them, both before `call` runs. [Contracts](../concepts/contracts.md) explains the pattern in full.

## Responses

A response defines the shape of the output:

<!-- prelude -->
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
    {
      id:    @user.id,    # Int64
      name:  @user.name,  # String
      email: @user.email, # String
    }.to_json
  end
end
```

The compiler verifies that every field exists on `User` and that its type can be serialized to JSON.

## Endpoints

An endpoint names its input and output types as the generic arguments of `Azu::Endpoint`:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑ Input type       ↑ Output type

  post "/users"

  def call : UserResponse # ← Must return this type
    name = create_user_request.name # String, not String?: no nil check needed

    # Optional fields are nilable: inside the `if`, age is an Int32
    if age = create_user_request.age
      age + 1
    end

    UserResponse.new(User.new(1_i64, name, create_user_request.email))
  end
end
```

The compiler ensures:
- `call` returns `UserResponse`
- All code paths return the correct type
- The request object has the expected shape

The declaration is also documentation that cannot go out of date. A Ruby method says nothing about what it takes:

```ruby
def process_order(order, options)
  # What is order? What are options?
  # Must read the implementation to understand
end
```

The first line of `CreateUserEndpoint` says what it accepts and what it returns, and the build fails as soon as the
code disagrees with it.

### What happens if you return the wrong type

This endpoint does not compile, which is the point:

<!-- skip -->
```crystal
def call : UserResponse
  if user = find_user
    UserResponse.new(user)
  else
    "Not found" # Error: method ShowUserEndpoint#call must return UserResponse but it is returning (String | UserResponse)
  end
end
```

The error is caught at compile time, not after deployment. A path that has no response to return raises an error
response instead, as the next example does.

## Nil safety

Route parameters are always strings, so converting one is explicit, and a lookup that can find nothing returns a
nilable type that the compiler makes you check:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # params["id"] is a String; to_i64? is nil when it is not a number
    user = params["id"].to_i64?.try { |id| User.find?(id) }

    # user is a User? (it might be nil), so `user.name` here would not compile:
    # Error: undefined method 'name' for Nil (compile-time type is (User | Nil))

    # The nil case must be handled
    if user
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{params["id"]}")
    end
  end
end
```

In Ruby, calling a method on `nil` raises `NoMethodError` (`undefined method for nil:NilClass`) in production; in
Crystal it is a build error.

## Union types

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

## Why Azu uses types

A web application serves users, so a crash affects real people, and a bug found by the compiler costs less than one
found in production. An API is a contract with its clients, and a type is a contract the compiler enforces. A team's
code is read by more people than wrote it, and the types tell each of them what a value is. Crystal compiles to
native code, and the types let the compiler dispatch methods directly, lay out values compactly and specialize
generic code instead of checking types at runtime (for measurements, see
[the benchmark suite](https://github.com/azutoolkit/azu/blob/master/benchmark/README.md)).

## Trade-offs

### Advantages

- Bugs are caught before deployment
- The code documents itself: types are documentation the compiler verifies
- Refactoring confidence: renaming a method or adding a constructor argument makes the build list every call site to
  update, where a dynamic language needs extensive test coverage or a text search
- Better IDE support: autocompletion, go to definition, find all references, inline documentation and rename
  refactoring work from the types

### Considerations

- More upfront type declarations: every field and constructor argument has a type, as `UserResponse` above shows
- A learning curve for developers from dynamic languages: union types, explicit `nil` handling and generics
- Less flexibility: some dynamic patterns do not translate. Ruby can call a method whose name arrives at runtime:

  ```ruby
  # Ruby metaprogramming
  user.send(method_name)
  ```

  Crystal needs to know the method at compile time, so dispatching on input is written out as a `case`, as
  `ItemEndpoint` does with `params["action"]`.

### Comparison

| Aspect | Dynamic (Ruby) | Static (Crystal) |
|--------|---------------|------------------|
| Error discovery | Runtime | Compile time |
| Refactoring | Manual/risky | Compiler-assisted |
| Documentation | Comments (outdated) | Types (verified) |
| IDE support | Limited | Full |
| Flexibility | High | Moderate |

## Best practices

1. **Be explicit about types**
   ```text
   def call : UserResponse  # Always specify return type
   ```

2. **Use union types sparingly; prefer one explicit type**

   Convert input to one type where it enters (a request contract does this for its fields) instead of accepting
   several types everywhere:

   ```text
   def find(id : Int64)  # rather than id : Int64 | String
   end
   ```

## See also

- [Contracts](../concepts/contracts.md)
- [Request](../../reference/api/request.md)
- [Response](../../reference/api/response.md)

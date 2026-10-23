# Why Type Safety?

This document explains why Azu embraces Crystal's type system and how it benefits web application development.

## The Cost of Runtime Errors

In dynamically typed web frameworks, errors often appear at runtime:

```ruby
# Ruby - Runtime errors
def show
  user = User.find(params[:id])
  render json: user.to_josn  # Typo: discovered when user hits this endpoint
end
```

These errors:
- Happen in production
- Affect real users
- Require monitoring to detect
- Need hotfixes to resolve

## Compile-Time Guarantees

Crystal catches errors before deployment:

```crystal
struct User
  getter name : String

  def initialize(@name)
  end
end

struct ShowResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    # Crystal - the typo is a compile-time error:
    #   @user.to_josn # Error: undefined method 'to_josn' for User
    @user.name
  end
end
```

The build fails. The error never reaches production.

## Types as Documentation

Types document code intent:

### Without Types

```ruby
def process_order(order, options)
  # What is order? What are options?
  # Must read implementation to understand
end
```

### With Types

```crystal
record Order, id : Int64
record ProcessOptions, express : Bool = false
record OrderResult, shipped : Bool

def process_order(order : Order, options : ProcessOptions) : OrderResult
  # Clear: Order in, ProcessOptions for config, OrderResult out
  OrderResult.new(options.express)
end
```

Types are documentation that can't become outdated.

## Refactoring Confidence

Types make refactoring safe:

### Scenario: Rename a Method

```crystal
# Before
class Person
  def initialize(@first_name : String, @last_name : String)
  end

  def full_name
    "#{@first_name} #{@last_name}"
  end
end

Person.new("Ada", "Lovelace").full_name

# After - rename to display_name
class Person
  def display_name
    "#{@first_name} #{@last_name}"
  end
end

# Compiler shows every call site that needs updating, because the
# call above no longer finds the old method once it is renamed:
# Error: undefined method 'full_name' for Person
```

In dynamic languages, you'd need extensive test coverage or grep.

## Request Contracts

A request contract declares its fields as types:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String  # Required, must be string
  getter email : String # Required, must be string
  getter age : Int32?   # Optional, must be integer if present

  def initialize(@name = "", @email = "", @age = nil)
  end
end
```

The compiler ensures:
- Your code handles every field with the right type
- Optional fields are checked for `nil` before use

At runtime Azu parses the request into those types, answering `400` for input that cannot be converted, and
runs the contract's `validate` rules, answering `422` for input that breaks them, both before your `call` runs.

## Response Type Enforcement

Endpoints declare their output:

```crystal
struct UserResponse
  include Azu::Response

  def render
    "user"
  end
end

struct UserEndpoint
  include Azu::Endpoint(Azu::Request, UserResponse)

  get "/user"

  def call : UserResponse # Must return UserResponse
    if params["ok"]? == "1"
      UserResponse.new
    else
      # "error" here would be a compile error: expected UserResponse
      raise Azu::Response::BadRequest.new("ok must be 1")
    end
  end
end
```

Every code path must return the declared type.

## Nil Safety

Crystal's nil-safety prevents null pointer errors:

```crystal
struct User
  getter name : String

  def initialize(@name)
  end

  def self.find?(id : Int64) : User?
    new("Ada") if id == 1
  end
end

user = User.find?(1_i64) # Returns User?

# user.name would be: Error: undefined method 'name' for Nil

if user
  user.name # Now compiler knows user is not nil
end
```

No more "undefined method for nil:NilClass" in production.

## IDE Support

Types enable powerful IDE features:
- Accurate autocompletion
- Go to definition
- Find all references
- Inline documentation
- Rename refactoring

## Performance Benefits

Crystal compiles to native code, and types let the compiler:
- Skip runtime type checks
- Dispatch methods directly
- Lay out values compactly
- Specialize generic code

## Trade-offs

### More Upfront Code

```crystal
struct User
  getter name : String

  def initialize(@name)
  end
end

# Must declare types
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    @user.name
  end
end
```

### Learning Curve

Developers from dynamic languages need to:
- Understand union types
- Handle nil explicitly
- Work with generics

### Less Flexibility

Some dynamic patterns don't translate:

```ruby
# Ruby metaprogramming
user.send(method_name)
```

```crystal
class Account
  def save
  end

  def delete
  end
end

# Crystal requires compile-time knowledge
def run(account : Account, method_name : String)
  case method_name
  when "save"
    account.save
  when "delete"
    account.delete
  end
end
```

## The Azu Position

Azu embraces types because:

1. **Web apps serve users** - Crashes affect real people
2. **APIs are contracts** - Types enforce contracts
3. **Teams scale** - Types help developers understand code
4. **Bugs are expensive** - Finding them early is cheaper
5. **Crystal is native** - Types let the compiler produce fast code

## Comparison

| Aspect | Dynamic (Ruby) | Static (Crystal) |
|--------|---------------|------------------|
| Error discovery | Runtime | Compile time |
| Refactoring | Manual/risky | Compiler-assisted |
| Documentation | Comments (outdated) | Types (verified) |
| IDE support | Limited | Full |
| Flexibility | High | Moderate |

## See Also

- [Type Safety in Azu](../architecture/type-safety.md)
- [Why Contracts](why-contracts.md)
- [Request Reference](../../reference/api/request.md)

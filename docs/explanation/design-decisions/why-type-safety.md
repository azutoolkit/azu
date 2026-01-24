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
# Crystal - Compile-time error
def call
  user = User.find(params["id"])
  user.to_josn  # Error: undefined method 'to_josn' for User
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
def process_order(order : Order, options : ProcessOptions) : OrderResult
  # Clear: Order in, ProcessOptions for config, OrderResult out
end
```

Types are documentation that can't become outdated.

## Refactoring Confidence

Types make refactoring safe:

### Scenario: Rename a Method

```crystal
# Before
class User
  def full_name
    "#{first_name} #{last_name}"
  end
end

# After - rename to display_name
class User
  def display_name
    "#{first_name} #{last_name}"
  end
end

# Compiler shows every call site that needs updating
# Error: undefined method 'full_name' for User
```

In dynamic languages, you'd need extensive test coverage or grep.

## Request Validation

Azu validates requests at compile time:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String       # Required, must be string
  getter email : String      # Required, must be string
  getter age : Int32?        # Optional, must be integer if present
end
```

The compiler ensures:
- Required fields are handled
- Types are correct
- Optional fields are properly checked

## Response Type Enforcement

Endpoints declare their output:

```crystal
struct UserEndpoint
  include Azu::Endpoint(Request, UserResponse)

  def call : UserResponse  # Must return UserResponse
    if condition
      UserResponse.new(user)
    else
      "error"  # Compile error: expected UserResponse
    end
  end
end
```

Every code path must return the declared type.

## Nil Safety

Crystal's nil-safety prevents null pointer errors:

```crystal
user = User.find?(id)  # Returns User?

user.name  # Error: undefined method 'name' for Nil

if user
  user.name  # Now compiler knows user is not nil
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

Types enable optimization:
- No runtime type checking
- Direct method dispatch
- Optimized memory layout
- Specialized generic code

## Trade-offs

### More Upfront Code

```crystal
# Must declare types
struct UserResponse
  include Azu::Response
  def initialize(@user : User)
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
# Crystal requires compile-time knowledge
case method_name
when "save"
  user.save
when "delete"
  user.delete
end
```

## The Azu Position

Azu embraces types because:

1. **Web apps serve users** - Crashes affect real people
2. **APIs are contracts** - Types enforce contracts
3. **Teams scale** - Types help developers understand code
4. **Bugs are expensive** - Finding them early is cheaper
5. **Crystal is fast** - Types enable performance

## Comparison

| Aspect | Dynamic (Ruby) | Static (Crystal) |
|--------|---------------|------------------|
| Error discovery | Runtime | Compile time |
| Refactoring | Manual/risky | Compiler-assisted |
| Documentation | Comments (outdated) | Types (verified) |
| IDE support | Limited | Full |
| Performance | Slower | Faster |
| Flexibility | High | Moderate |

## See Also

- [Type Safety in Azu](../architecture/type-safety.md)
- [Why Contracts](why-contracts.md)
- [Request Reference](../../reference/api/request.md)

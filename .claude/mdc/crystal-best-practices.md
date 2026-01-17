# Crystal Best Practices MDC

> **Domain:** Crystal Language Conventions & Safety
> **Applies to:** All `.cr` files in this project

## Type Safety Enforcement

### Always Specify Return Types
```crystal
# CORRECT: Explicit return type
def find_user(id : Int64) : User?
  User.find(id)
end

# INCORRECT: Missing return type on public method
def find_user(id)
  User.find(id)
end
```

### Use Generics for Type-Safe Contracts
```crystal
# CORRECT: Generic constraint ensures compile-time safety
struct Endpoint(Request, Response)
  def call(request : Request) : Response
  end
end

# Use in implementations
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)
end
```

### Prefer Struct Over Class for Value Objects
```crystal
# CORRECT: Immutable value object
struct Point
  getter x : Float64
  getter y : Float64
end

# CORRECT: Stateful entity uses class
class Connection
  property socket : TCPSocket
  property connected : Bool = false
end
```

### Nil Safety Patterns
```crystal
# CORRECT: Handle nil explicitly
if user = find_user(id)
  user.name
else
  "Unknown"
end

# CORRECT: Use try for optional chaining
user.try(&.profile).try(&.avatar_url) || default_avatar

# AVOID: Force unwrapping without guard
user.not_nil!.name  # Only when nil is impossible
```

## Effective Use of Shards

### Dependency Declaration
```yaml
# shard.yml - Pin versions for reproducibility
dependencies:
  radix:
    github: luislavena/radix
    version: ~> 0.4.1  # Semantic versioning constraint

  redis:
    github: stefanwille/crystal-redis
    version: ~> 2.9.0
```

### Require Order
```crystal
# 1. Standard library
require "http/server"
require "json"

# 2. External shards (alphabetically)
require "radix"
require "redis"
require "schema"

# 3. Local modules (by dependency order)
require "./configuration"
require "./router"
require "./endpoint"
```

### Avoid Shard Conflicts
```crystal
# Use module namespacing to avoid collisions
module Azu
  # Wrap external types if needed
  alias CacheStore = Redis::PooledClient | MemoryStore
end
```

## Error Handling Patterns

### Custom Exception Hierarchy
```crystal
# Base error for domain
class AzuError < Exception
  getter code : Int32

  def initialize(@message : String, @code = 500)
    super(@message)
  end
end

# Specific errors inherit from base
class ValidationError < AzuError
  getter fields : Array(String)

  def initialize(@fields, message = "Validation failed")
    super(message, 422)
  end
end

class AuthenticationError < AzuError
  def initialize(message = "Authentication required")
    super(message, 401)
  end
end
```

### Error Context Propagation
```crystal
# Always include context for debugging
begin
  process_request(request)
rescue ex : ValidationError
  error_context = ErrorContext.new(
    request_id: context.request_id,
    endpoint: self.class.name,
    ip: context.request.remote_address
  )
  raise ValidationError.new(ex.fields, ex.message, error_context)
end
```

### Result Types for Expected Failures
```crystal
# Use union types for operations that can fail expectedly
def parse_config(path : String) : Config | ConfigError
  # Return error instead of raising for expected failures
  return ConfigError.new("File not found") unless File.exists?(path)
  Config.from_yaml(File.read(path))
rescue YAML::ParseException => ex
  ConfigError.new("Invalid YAML: #{ex.message}")
end

# Caller handles both cases
case result = parse_config("config.yml")
when Config
  result.database_url
when ConfigError
  Log.error { result.message }
  exit(1)
end
```

## Memory & Performance

### Avoid Allocations in Hot Paths
```crystal
# INCORRECT: Creates new string on each call
def format_path(path : String) : String
  "/" + path.lstrip("/")
end

# CORRECT: Avoid allocation when not needed
def format_path(path : String) : String
  path.starts_with?("/") ? path : "/#{path}"
end
```

### Use Slices for Binary Data
```crystal
# CORRECT: Zero-copy binary handling
def process_chunk(data : Bytes) : Bytes
  data[0, 1024]  # Returns slice, no copy
end

# AVOID: Converting to Array unnecessarily
def process_chunk(data : Bytes) : Array(UInt8)
  data.to_a  # Creates new array, copies data
end
```

### Lazy Initialization
```crystal
# CORRECT: Lazy singleton pattern
class Registry
  @@instance : Registry?

  def self.instance : Registry
    @@instance ||= new
  end
end

# Or use class getter macro
class Registry
  class_getter instance : Registry { new }
end
```

## Thread Safety

### Mutex for Shared State
```crystal
class ThreadSafeCache(K, V)
  @mutex = Mutex.new
  @data = {} of K => V

  def get(key : K) : V?
    @mutex.synchronize { @data[key]? }
  end

  def set(key : K, value : V) : V
    @mutex.synchronize { @data[key] = value }
  end
end
```

### Atomic Operations
```crystal
# Use Atomic for simple counters
class RequestCounter
  @count = Atomic(Int64).new(0)

  def increment : Int64
    @count.add(1)
  end

  def get : Int64
    @count.get
  end
end
```

## Macro Best Practices

### Keep Macros Simple
```crystal
# CORRECT: Single-purpose macro
macro route(method, path)
  CONFIG.router.{{method.id}}({{path}}, self.new)
end

# Use in code
route :get, "/users"
route :post, "/users"
```

### Avoid Macro Overuse
```crystal
# AVOID: Complex logic in macros
macro complex_validation
  {% for field in @type.instance_vars %}
    {% if field.annotation(Validate) %}
      # Complex validation logic...
    {% end %}
  {% end %}
end

# PREFER: Move logic to runtime where possible
def validate : Bool
  VALIDATORS.each do |validator|
    return false unless validator.call(self)
  end
  true
end
```

## Documentation

### Document Public APIs
```crystal
# Brief description on first line
#
# Longer description if needed, explaining behavior,
# edge cases, and usage patterns.
#
# Parameters:
# - `id` : The user's unique identifier
# - `include_deleted` : Whether to include soft-deleted users
#
# Returns: The user if found, nil otherwise
#
# Raises:
# - `DatabaseError` if connection fails
#
# Example:
# ```
# user = find_user(123)
# user.try(&.name) # => "John"
# ```
def find_user(id : Int64, include_deleted : Bool = false) : User?
end
```

## Testing

### Descriptive Test Names
```crystal
describe UserEndpoint do
  describe "#call" do
    it "returns 201 with valid user data" do
    end

    it "returns 422 when email is invalid" do
    end

    it "returns 409 when email already exists" do
    end
  end
end
```

### Test Isolation
```crystal
# Each test should be independent
before_each do
  Database.clear
  Cache.clear
end

after_each do
  # Cleanup any side effects
end
```

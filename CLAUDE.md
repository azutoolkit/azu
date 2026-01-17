# Azu Framework - Claude Code Development Guide

## Project Overview

Azu is a high-performance, type-safe web framework for Crystal that emphasizes developer productivity, compile-time safety, and real-time capabilities. It follows the "fast as C, slick as Ruby" philosophy.

**Type:** Web Framework (Library)
**Crystal Version:** 1.17.1+ (minimum 0.35.0)
**License:** MIT

## Quick Reference Commands

```bash
# Build
shards install              # Install dependencies
shards build                # Build targets from shard.yml
crystal build playground/example_app.cr  # Build example app

# Test
crystal spec                # Run all tests
crystal spec spec/integration/  # Run integration tests only
crystal spec --tag focus    # Run focused tests

# Lint & Format
crystal tool format         # Format code
crystal tool format --check # Check formatting (CI)
ameba                       # Run static analysis

# Documentation
crystal docs                # Generate API documentation
crystal docs --output=docs/api  # Custom output directory

# Development
crystal run playground/example_app.cr  # Run example app
```

## Project Structure

```
src/azu/
├── azu.cr              # Core module & startup
├── router.cr           # Radix-tree routing with path caching
├── endpoint.cr         # Type-safe request handlers
├── request.cr          # Request contracts with validation
├── response.cr         # Response objects & error classes
├── channel.cr          # WebSocket channel handlers
├── spark.cr            # Real-time component system
├── component.cr        # Live components with pooling
├── cache.cr            # Multi-store caching (Memory/Redis)
├── params.cr           # Parameter extraction & uploads
├── handler/            # Middleware handlers (12 files)
└── templates.cr        # Crinja template engine

spec/
├── integration/        # Integration test suites
└── azu/handler/        # Handler-specific tests

playground/             # Example application
docs/                   # Comprehensive documentation
```

## Core Patterns

### Endpoint Definition

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # request object auto-validated from params
    UserResponse.new(user_request)
  end
end
```

### Request Contract

```crystal
struct UserRequest
  include Azu::Request

  @name : String
  @email : String

  validate name, presence: true, length: {min: 2}
  validate email, presence: true, format: /@/
end
```

### Response Object

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User); end

  def render
    {id: @user.id, name: @user.name}.to_json
  end
end
```

### WebSocket Channel

```crystal
class ChatChannel < Azu::Channel
  def on_message(message : String)
    broadcast("chat", message)
  end
end
```

## Code Style Guidelines

### Naming Conventions

- **Classes/Modules:** PascalCase (`UserEndpoint`, `AuthHandler`)
- **Methods/Variables:** snake_case (`create_user`, `user_id`)
- **Constants:** UPPER_SNAKE_CASE (`MAX_CACHE_SIZE`)
- **Type Parameters:** Single uppercase (`T`, `Request`, `Response`)

### File Organization

- One main type per file
- Nested types in same file if tightly coupled
- Handler classes in `handler/` subdirectory
- Test files mirror source structure in `spec/`

### Type Safety Requirements

- Always specify return types on public methods
- Use generics for type-safe contracts: `Endpoint(RequestType, ResponseType)`
- Prefer `struct` for value objects, `class` for stateful entities
- Use union types sparingly; prefer explicit types

### Error Handling

```crystal
# Custom errors inherit from Response::Error
class CustomError < Azu::Response::Error
  def initialize(message : String, context : ErrorContext? = nil)
    super(message, 400, context)
  end
end

# Always include context for debugging
error_context = ErrorContext.from_http_context(context, request_id)
raise CustomError.new("Invalid input", error_context)
```

### Thread Safety

- Use `Mutex.synchronize` for shared state
- Component registry uses thread-safe patterns
- Cache stores are mutex-protected
- Avoid global mutable state

## Testing Patterns

### Unit Test Structure

```crystal
describe MyHandler do
  it "handles valid request" do
    context = create_context(method: "GET", path: "/test")
    handler.call(context)
    context.response.status_code.should eq 200
  end
end
```

### Integration Tests

- Spawn example app in background
- Use HTTP client for real requests
- Kill process on suite completion

### Test Helpers

```crystal
include IntegrationHelpers  # Context creation utilities

def create_context(method : String, path : String, body : String? = nil)
  # Helper for creating HTTP context
end
```

## Performance Considerations

### Compile-Time Flags

```crystal
# Enable performance monitoring (compile-time)
{% if env("PERFORMANCE_MONITORING") == "true" %}
  require "./performance_metrics"
{% end %}
```

### Caching Strategy

- Router uses path caching (1000 entry limit, LRU)
- Component pooling (max 50 per type)
- Template caching with optional hot-reload
- Multi-store cache: Memory (default), Redis (production)

### Optimization Checklist

- [ ] Use struct for value objects (stack allocation)
- [ ] Enable path caching for repeated routes
- [ ] Pool frequently-created components
- [ ] Use compile-time conditionals for optional features

## Dependencies

| Shard          | Purpose                  |
| -------------- | ------------------------ |
| radix          | High-performance routing |
| exception_page | Beautiful error pages    |
| schema         | Type-safe validation     |
| crinja         | Jinja2 template engine   |
| redis ~> 2.9.0 | Caching & sessions       |

## CI/CD Notes

- **Linter:** Ameba with max cyclomatic complexity of 10
- **Container:** crystallang/crystal:1.17.1
- **Services:** Redis required for cache tests
- **Excluded from complexity:** performance_monitor, components, demo_reporting

## Common Tasks

### Adding a New Endpoint

1. Create request struct with validations
2. Create response struct with render method
3. Create endpoint with HTTP method macro
4. Add tests in spec/integration/

### Adding Middleware

1. Create handler in `src/azu/handler/`
2. Implement `call(context)` method
3. Chain with `next.try &.call(context)`
4. Add to handler pipeline in configuration

### Adding a Component

1. Create class including `Azu::Component`
2. Implement `content` method
3. Register event handlers with `on_event`
4. Add to Spark system for real-time updates

## Troubleshooting

### Common Issues

- **Route not found:** Check macro registration with `get`, `post`, etc.
- **Validation errors:** Ensure request includes `Azu::Request` module
- **WebSocket issues:** Verify channel inherits from `Azu::Channel`
- **Cache misses:** Check TTL settings and store configuration

### Debug Mode

```crystal
Azu.configure do |config|
  config.env = Environment::Development
  config.template_hot_reload = true
end
```

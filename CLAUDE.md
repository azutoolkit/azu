# Azu Framework - Claude Code Development Guide

## Project Overview

Azu is a high-performance, type-safe web framework for Crystal that emphasizes developer productivity, compile-time safety, and real-time capabilities. It follows the "fast as C, slick as Ruby" philosophy.

**Type:** Web Framework (Library)
**Crystal Version:** 1.19.1+ (the oldest version CI tests; `shard.yml` declares the same floor)
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
├── app.cr              # Azu::App: an app as a value (config + router), App.default wraps the global CONFIG
├── routable.cr         # Azu::Routable: what the router dispatches to (endpoints, upgraders, plain handlers)
├── router.cr           # Radix-tree routing with path caching
├── openapi/            # Azu::OpenAPI: OpenAPI 3.1 document from Endpoint contracts + Handler (docs/reference/api/openapi.md)
├── endpoint.cr         # Type-safe request handlers
├── request.cr          # Request contracts with validation
├── response.cr         # Response objects & error classes
├── channel.cr          # WebSocket channel handlers
├── spark.cr            # Real-time component system
├── component.cr        # Static markup components (`Azu::Component`)
├── cache.cr            # Multi-store caching (Memory/Redis)
├── params.cr           # Parameter extraction & uploads
├── handler/            # Middleware handlers (12 files)
├── templates.cr        # Crinja template engine
├── instrumentation.cr  # The seam optional subsystems plug into: cache/component hooks, prepare/finalize hooks
├── query_store.cr      # Query/transaction telemetry + N+1 analysis (fed by azu/cql, read by the dashboard)
├── request_context.cr  # Fiber-keyed current request for tagging SQL/logs
├── cql/                # Opt-in CQL bridge (`require "azu/cql"`), see docs/reference/database-dashboard.md
├── dev/                # Opt-in dev tooling (`require "azu/dev"`, entry point dev/dev.cr)
│   ├── configuration.cr        # Configuration#performance_*, #performance_monitor, #development_tools
│   ├── performance_metrics.cr  # Request/cache/component metrics
│   ├── performance_monitor.cr  # Handler::PerformanceMonitor
│   ├── performance_reporter.cr # Log/JSON reporters
│   ├── development_tools.cr    # Profiler, memory leak detector
│   ├── dev_dashboard.cr        # Handler::DevDashboard
│   └── dev_dashboard_component.cr + dev_dashboard/  # The dashboard page and its sections
└── helpers/            # Template helpers DSL
    ├── helpers.cr      # Main require & DSL macros
    ├── registry.cr     # Thread-safe helper registration
    ├── context.cr      # HTTP context for templates
    ├── i18n.cr         # Internationalization system
    ├── util.cr         # Shared utility functions
    └── builtin/        # Built-in helpers
        ├── form_helpers.cr
        ├── asset_helpers.cr
        ├── url_helpers.cr
        ├── component_helpers.cr
        ├── date_helpers.cr
        ├── number_helpers.cr
        └── html_helpers.cr

spec/
├── integration/        # Integration test suites
├── azu/handler/        # Handler-specific tests
└── azu/dev/            # azu/dev specs (they require "../../../src/azu/dev/dev")

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

  getter name : String
  getter email : String

  validate name, presence: true, size: 2..50
  validate email, presence: true, match: /@/
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
  # All six callbacks are abstract: implement every one, even if empty
  def on_connect
    subscribe "chat"
  end

  def on_message(message : String)
    broadcast("chat", message)
  end

  def on_binary(binary : Bytes)
  end

  def on_ping(message : String)
  end

  def on_pong(message : String)
  end

  def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)
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

### Optional Subsystems

The dev dashboard, performance monitor, profiler and reporter live in `src/azu/dev/` and load with
`require "azu/dev"`. Core only calls `Azu::Instrumentation` (a nil check without subscribers), so
`require "azu"` alone pays nothing. Building with `PERFORMANCE_MONITORING=true` makes `require "azu"` load
`azu/dev` too.

### Caching Strategy

- Router path cache: stops adding entries at 1000 (no eviction, no LRU); `path_cache.stats` reports
  `fill_percent`, not a hit rate
- No component pooling: components are plain objects created where they are rendered
- Azu does not cache templates: `Templates#load` asks Crinja every time; the hot-reload flag only
  controls checking template files for changes
- Multi-store cache: Memory (default), Redis (production)

### Optimization Checklist

- [ ] Use struct for value objects (stack allocation)
- [ ] Enable path caching for repeated routes
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
- **Container:** crystallang/crystal:1.19.1
- **Services:** Redis required for cache tests
- **Excluded from complexity:** dev/ (performance_monitor, performance_reporter, dev_dashboard_component), demo_reporting

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

1. Static markup: create a class including `Azu::Component` and implement `content`
2. Live views: inherit `Azu::Spark::Component`, declare `prop`/`state`, implement `render`
3. Expose client events with `event def` and bind them with `spark_click` etc.
4. Render with `Azu::Spark.render` (see `docs/explanation/spark-live-views.md`)

## Template Helpers

Azu provides built-in template helpers for common web development tasks.

### Quick Reference

```jinja
{# Forms #}
{{ form_tag("/users", method="post") }}
  {{ csrf_field() }}
  {{ text_field("user", "name", required=true) }}
  {{ submit_button("Create") }}
{{ end_form() }}

{# Links #}
{{ link_to("Home", "/", class="nav-link") }}
{{ button_to("Delete", "/posts/1", method="delete") }}

{# Assets #}
{{ stylesheet_tag("app.css") }}
{{ javascript_tag("app.js") }}
{{ image_tag("logo.png", alt="Logo") }}

{# i18n #}
{{ t("welcome.title") }}
{{ t("greeting", name=user.name) }}
{{ date | l("date.short") }}

{# Numbers #}
{{ price | currency("$") }}
{{ count | number_with_delimiter }}

{# Dates #}
{{ created_at | time_ago }}
{{ date | date_format("%Y-%m-%d") }}

{# HTML #}
{{ content | safe_html }}
{{ text | highlight("search") }}
```

### Custom Helpers

```crystal
# Register a custom filter
Azu::Helpers.filter :shout do
  target.to_s.upcase + "!"
end

# Register a custom function
Azu::Helpers.function :greet do
  "Hello, #{arguments["name"]}!"
end
```

See `docs/reference/templates/helpers.md` for full documentation.

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

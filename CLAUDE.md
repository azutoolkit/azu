# Azu Framework - Claude Code Development Guide

## Project Overview

Azu is a high-performance, type-safe web framework for Crystal that emphasizes developer productivity, compile-time safety, and real-time capabilities. It follows the "fast as C, slick as Ruby" philosophy.

**Type:** Web Framework (Library)
**Crystal Version:** 1.22.1+ (the oldest version CI tests; `shard.yml` declares the same floor)
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
crystal run lib/ameba/bin/ameba.cr -- ./src  # Static analysis, as CI's Lint step runs it

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
├── env.cr              # Azu::Env: `.env` loading, typed ENV accessors, `secret` (random outside the strict environments, error inside: production and staging by default, `AZU_STRICT_ENVS`), `require_at_boot` (names `App#start` checks before binding); standalone (`require "azu/env"`), no work at require time (`.env` files skip the CLI's denylist, i.e. LD_*/PATH/HOME/CRYSTAL_*/GIT_*/compiler and *FLAGS/proxy/cert/locale/TZ names, ... unless `unsafe: true`; `secret` warns once on the random fallback). Inside the app the rule is `Azu.strict_environment?` (CRYSTAL_ENV or `config.env`)
├── clock.cr            # Azu::Clock: the time source for TTLs, windows and token lifetimes; Clock::Fake + `with_fake_clock` in specs
├── app.cr              # Azu::App: an app as a value (config + router + #start/#stop lifecycle), App.default wraps the global CONFIG; `include Azu` is the supported single-app facade over it. `start` runs `Configuration#check_boot` first (CRYSTAL_ENV unset on a public host, SSL_CERT xor SSL_KEY, WebSocket limits, `Env.required_at_boot`: BootError / MissingError before anything binds)
├── routable.cr         # Azu::Routable: what the router dispatches to (endpoints, upgraders, plain handlers)
├── router.cr + router/ # Routing on an in-house segment tree (router/tree.cr); `App#start` freezes the routers
├── openapi/            # Azu::OpenAPI: OpenAPI 3.1 document from Endpoint contracts + Handler (docs/reference/api/openapi.md)
├── endpoint.cr         # Type-safe request handlers
├── request.cr          # Request contracts with validation
├── response.cr         # Response objects & error classes
├── response/           # Negotiable (Accept), Stream, EventStream (SSE), NotAcceptable
├── negotiation.cr      # Accept parsing & format selection
├── channel.cr          # WebSocket channel handlers
├── presence.cr + presence/  # Azu::Presence: who is in a topic across nodes (Tracker, Store::Memory/Redis, Tracked channel module)
├── spark.cr            # Real-time component system
├── spark/client/azu_spark.js  # GENERATED minified Spark client; edit js/azu-spark.js, then `npm run build` in js/
├── component.cr        # Static markup components (`Azu::Component`)
├── cache.cr            # Multi-store caching (Memory/Redis)
├── redis.cr + redis/   # Azu::Redis: the one Redis pool/config/retry that cache, pubsub and presence share
├── params.cr           # Parameter extraction & uploads
├── handler/            # Middleware handlers; throttle/ holds Throttle::Store (Memory, Redis). Default stack: RequestId, Logger, Rescuer, SecurityHeaders (hsts :auto), Static; `start(handlers, defaults: true)` composes. CSRF checks Origin/Referer (CORS marks allowed origins on the request: `cors_allowed?`); `config.trusted_proxies` decides whose X-Forwarded-* are believed (TemplateContext, Throttle)
├── templates.cr        # Crinja template engine
├── instrumentation.cr  # The seam optional subsystems plug into: cache/component/exception hooks, prepare/finalize hooks
├── exception_page.cr + exception_page/  # Development exception page: Report (frames, redacted request), triage hints (`ExceptionPage.hint`), panels (`ExceptionPage.on_panels`, core Database panel), page.cr/css/js; production uses templates/error.html
├── ui/                 # Markup widgets, status/format vocabulary, dashboard.css, theme_boot.js, icons.svg: shared by the dev dashboard and the exception page
├── query_store.cr      # Query/transaction telemetry + N+1 analysis (fed by azu/cql, read by the dashboard)
├── request_context.cr  # Fiber-keyed current request for tagging SQL/logs
├── cql/                # Opt-in CQL bridge (`require "azu/cql"`), see docs/reference/database-dashboard.md; driver.cr picks CQL's native engine pool (default for postgres://) or crystal-db (`driver: :db`, `AZU_CQL_DRIVER`)
├── testing/            # Opt-in test client (`require "azu/testing"`, entry point testing/testing.cr): Client, WebSocket, Sessions, CookieJar
├── dev/                # Opt-in dev tooling (`require "azu/dev"`, entry point dev/dev.cr)
│   ├── configuration.cr        # Configuration#performance_*, #performance_monitor, #development_tools
│   ├── performance_metrics.cr  # Request/cache/component metrics
│   ├── performance_monitor.cr  # Handler::PerformanceMonitor
│   ├── performance_reporter.cr # Log/JSON reporters
│   ├── development_tools.cr    # Profiler, memory leak detector
│   ├── telemetry.cr            # Dev::Telemetry: 1 Hz JSON snapshots to azu dev's dashboard over AZU_TELEMETRY_SOCKET
│   ├── dev_dashboard.cr        # Handler::DevDashboard (also /errors/<id>, errors.json)
│   ├── error_store.cr          # ErrorStore: server errors kept for the Errors tab (fed by Instrumentation.on_exception)
│   ├── exception_signals.cr    # The exception page's "Performance context" panel
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

js/                     # Spark client source (azu-spark.js), build.mjs, typings, node tests (dev-only node)
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

- Router: no path cache. A static route is found without allocating; a route with parameters allocates only their
  values and the params hash (`clear_path_cache` is kept and does nothing)
- No component pooling: components are plain objects created where they are rendered
- Templates: with `template_hot_reload` off (default outside development/test/pipeline) they are preloaded:
  `Azu.prepare` reads and parses every template file once into an immutable name => template map (the Crinja
  environment's loader, so includes/extends use it too) and `Templates#load` is a hash lookup; a syntax error
  fails the boot (`template_preload_ignore` globs opt files out). With it on (development) `Templates#load` checks mtimes and Crinja re-reads the file
- Multi-store cache: Memory (default), Redis (production)

### Optimization Checklist

- [ ] Use struct for value objects (stack allocation)
- [ ] Use compile-time conditionals for optional features

## Dependencies

| Shard          | Purpose                  |
| -------------- | ------------------------ |
| schema         | Type-safe validation     |
| crinja         | Jinja2 template engine   |
| redis ~> 2.9.0 | Caching & sessions       |

## CI/CD Notes

- **Linter:** Ameba (`ameba ~> 1.7.0`, a development dependency) on `src/` in the `test` job, max cyclomatic complexity
  10; `.ameba.yml` excludes, per rule, the files that broke it when the step was added (a baseline to shrink)
- **Container:** crystallang/crystal:1.22.1
- **Services:** Redis required for cache tests
- **Excluded from complexity:** dev/ (performance_monitor, performance_reporter, dev_dashboard_component), demo_reporting
- **Releases:** every green push to master is a release: the `release` job commits the `shard.yml` version
  straight to master and tags that commit (no bump PR; it pushes with the `RELEASE_TOKEN` secret, as master is
  protected). Do not bump `shard.yml` by hand; put `(MINOR)` or `(MAJOR)` in a commit message to pick the bump

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

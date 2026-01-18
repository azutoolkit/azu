# Azu Web Framework

**Azu** is a high-performance web framework for Crystal emphasizing type safety, modularity, and real-time capabilities.

## Quick Example

```crystal
require "azu"

module MyApp
  include Azu

  configure do
    port = 3000
  end
end

struct HelloRequest
  include Azu::Request
  getter name : String = "World"
end

struct HelloResponse
  include Azu::Response
  def initialize(@name : String); end
  def render
    "Hello, #{@name}!"
  end
end

struct HelloEndpoint
  include Azu::Endpoint(HelloRequest, HelloResponse)
  get "/"
  def call : HelloResponse
    HelloResponse.new(hello_request.name)
  end
end

MyApp.start [
  Azu::Handler::Logger.new,
  Azu::Handler::Rescuer.new
]
```

## Architecture

```text
HTTP Request → Router → Middleware Chain → Endpoint → Response
                                              ↓
                                    Request Contract (validation)
```

**Endpoints** are type-safe handlers with:

- **Request Contract**: Validates and types incoming data
- **Response Object**: Handles content rendering
- **Middleware**: Cross-cutting concerns (auth, logging, etc.)

## Core Features

| Feature                 | Description                                 |
| ----------------------- | ------------------------------------------- |
| **Type-Safe Contracts** | Compile-time validation via `Azu::Request` |
| **Radix Routing**       | O(log n) lookup with path caching          |
| **WebSocket Channels**  | Real-time bidirectional communication      |
| **Live Components**     | Server-rendered with client sync (Spark)   |
| **Multi-Store Cache**   | Memory and Redis with auto-metrics         |
| **Middleware Stack**    | CORS, CSRF, Rate Limiting, Logging         |

## Documentation

### Getting Started

- [Installation](getting-started/installation.md)
- [First App](getting-started/first-app.md)

### Core Concepts

- [Architecture](fundamentals/architecture.md)
- [Endpoints](fundamentals/endpoints.md)
- [Requests](fundamentals/requests.md)
- [Responses](fundamentals/responses.md)
- [Routing](fundamentals/routing.md)
- [Middleware](fundamentals/middleware.md)

### Features

- [Caching](features/caching.md)
- [Templates](features/templates.md)
- [Validation](features/validation.md)
- [File Uploads](features/file-uploads.md)

### Real-Time

- [WebSocket Channels](real-time/channels.md)
- [Live Components](real-time/components.md)
- [Spark System](real-time/spark.md)

### Advanced

- [Performance Tuning](advanced/performance-tuning.md)
- [Content Negotiation](advanced/content-negotiation.md)
- [Environments](advanced/environments.md)
- [Development Dashboard](advanced/development-dashboard.md)

### API Reference

- [Core API](api/core.md)
- [Handlers](api/handlers.md)
- [Configuration](api/configuration.md)
- [Errors](api/errors.md)

### Deployment

- [Production](deployment/production.md)
- [Docker](deployment/docker.md)
- [Scaling](deployment/scaling.md)

### Testing

- [Unit Testing](testing/unit.md)
- [Integration Testing](testing/integration.md)
- [WebSocket Testing](testing/websockets.md)

### More

- [FAQ](faq.md)
- [Version Upgrades](migration/upgrades.md)
- [Contributing](contributing/setup.md)

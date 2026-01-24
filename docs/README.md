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

| New to Azu? | Need to do something? | Looking for API? | Want to understand? |
|-------------|----------------------|------------------|---------------------|
| [Tutorials](tutorials/) | [How-To Guides](how-to/) | [Reference](reference/) | [Explanation](explanation/) |

### Tutorials

Step-by-step lessons to learn Azu:

- [Getting Started](tutorials/getting-started.md) - Install and create your first app
- [Building a User API](tutorials/building-a-user-api.md) - Complete CRUD API tutorial
- [Adding WebSockets](tutorials/adding-websockets.md) - Real-time features
- [Working with Databases](tutorials/working-with-databases.md) - CQL integration
- [Testing Your App](tutorials/testing-your-app.md) - Write comprehensive tests
- [Deploying to Production](tutorials/deploying-to-production.md) - Production deployment

### How-To Guides

Task-oriented guides for specific goals:

- [Endpoints](how-to/endpoints/) - Create endpoints, handle parameters, return formats
- [Validation](how-to/validation/) - Validate requests and models
- [Real-Time](how-to/real-time/) - WebSocket channels and live components
- [Database](how-to/database/) - Schema, models, queries, transactions
- [Caching](how-to/caching/) - Memory and Redis caching
- [Middleware](how-to/middleware/) - Custom handlers and logging
- [Deployment](how-to/deployment/) - Production, Docker, scaling
- [Performance](how-to/performance/) - Optimize endpoints and queries

### Reference

Technical specifications and API documentation:

- [Core API](reference/api/) - Endpoint, Request, Response, Channel, Component
- [Handlers](reference/handlers/built-in.md) - Built-in middleware handlers
- [Configuration](reference/configuration/options.md) - All configuration options
- [Database](reference/database/) - CQL API, validations, query methods
- [Error Types](reference/errors/error-types.md) - HTTP error classes

### Explanation

Conceptual understanding of Azu:

- [Architecture](explanation/architecture/overview.md) - How Azu works
- [Request Lifecycle](explanation/architecture/request-lifecycle.md) - Request flow
- [Type Safety](explanation/architecture/type-safety.md) - Compile-time guarantees
- [Design Decisions](explanation/design-decisions/) - Why Azu is built this way

### Resources

- [FAQ](faq.md) - Common questions and troubleshooting
- [Contributing](contributing/setup.md) - Development setup and guidelines

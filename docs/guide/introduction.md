# Introduction to Azu

Azu is a modern, type-safe web framework for the Crystal programming language that emphasizes performance, developer experience, and elegant syntax. Built with Crystal's powerful type system and compile-time guarantees, Azu provides a robust foundation for building web applications, APIs, and real-time systems.

## What is Azu?

Azu is designed around the principle of **type safety first**. Every request, response, and data flow is validated at compile time, eliminating entire classes of runtime errors and providing exceptional developer confidence.

### Key Philosophy

- **Type Safety**: Leverage Crystal's static type system for compile-time guarantees
- **Performance**: Built for speed with minimal overhead and efficient resource usage
- **Developer Experience**: Intuitive APIs with excellent error messages and tooling
- **Modularity**: Component-based architecture that scales from simple APIs to complex applications
- **Real-time Ready**: Built-in WebSocket support and live components for interactive applications

## Why Choose Azu?

### For Crystal Developers

Azu embraces Crystal's strengths while providing a modern web development experience:

- **Zero Runtime Type Errors**: Catch issues at compile time, not in production
- **Exceptional Performance**: Near-native speed with Crystal's compiled nature
- **Memory Safety**: No garbage collection pauses or memory leaks
- **Concurrent by Design**: Built-in support for high-concurrency applications

### For Web Developers

Familiar patterns with Crystal's power:

- **RESTful by Default**: Intuitive routing and resource handling
- **Real-time Capabilities**: WebSocket channels and live components out of the box
- **Template Engine**: Powerful Jinja2-compatible templating with hot reload
- **Middleware Chain**: Flexible request/response processing pipeline

### For API Developers

Type-safe APIs that are a joy to build and maintain:

- **Request Contracts**: Validate and type incoming data automatically
- **Response Objects**: Structured, type-safe response handling
- **Content Negotiation**: Support multiple formats (JSON, XML, HTML) seamlessly
- **Error Handling**: Comprehensive error types with proper HTTP status codes

## Core Concepts

### Endpoints: The Heart of Azu

Every route in Azu is handled by an **Endpoint** - a type-safe, testable object that defines exactly what data it accepts and returns:

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # Your business logic here
    UserResponse.new(user: find_user(user_request.id))
  end
end
```

### Request Contracts

Define exactly what data your endpoints expect:

```crystal
struct UserRequest
  include Azu::Request

  @id : Int32
  @email : String

  validate id, presence: true
  validate email, format: /^[^@]+@[^@]+\.[^@]+$/
end
```

### Response Objects

Structure your responses with type safety:

```crystal
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {user: @user, timestamp: Time.utc}
  end
end
```

## Real-time Capabilities

Azu includes powerful real-time features for building interactive applications:

### WebSocket Channels

```crystal
class ChatChannel < Azu::Channel
  ws "/chat/:room"

  def on_connect
    # Handle connection
  end

  def on_message(message)
    # Broadcast to room
  end
end
```

### Live Components

Build interactive UI components that update in real-time:

```crystal
class CounterComponent
  include Azu::Component

  def content
    div do
      text "Count: #{@count}"
      button "Increment", onclick: "increment"
    end
  end

  def on_event("increment", data)
    @count += 1
    update!
  end
end
```

## Performance Characteristics

Azu is built for performance:

- **Compile-time Optimization**: Crystal's compiler optimizes your code
- **Memory Efficiency**: Predictable memory usage with no GC pauses
- **Concurrent Processing**: Handle thousands of connections efficiently
- **Built-in Caching**: Smart caching strategies for common patterns
- **Performance Monitoring**: Real-time metrics and profiling tools

## Getting Started

Ready to build with Azu? Here's how to get started:

1. **[Quick Start Guide](quickstart.md)** - Get running in 5 minutes
2. **[Installation](installation.md)** - Detailed setup instructions
3. **[Tutorial](tutorial.md)** - Build your first application
4. **[Architecture Overview](../fundamentals/architecture.md)** - Understand the system design

## Community and Support

- **GitHub**: [Report issues and contribute](https://github.com/your-org/azu)
- **Discord**: [Join our community](https://discord.gg/your-server)
- **Documentation**: Comprehensive guides and API reference
- **Examples**: Real-world applications and patterns

## What's Next?

- **[Quick Start](quickstart.md)** - Build your first Azu application in 5 minutes
- **[Architecture](fundamentals/architecture.md)** - Understand how Azu works under the hood
- **[Endpoints](fundamentals/endpoints.md)** - Learn the core building blocks
- **[Real-time Features](features/websockets.md)** - Build interactive applications

---

_Ready to experience the power of type-safe web development? Let's get started!_

# Architecture Overview

This document explains the high-level architecture of Azu and how its components work together.

## Design Philosophy

Azu follows Crystal's philosophy of being "fast as C, slick as Ruby." The framework emphasizes:

1. **Type Safety** - Catch errors at compile time, not runtime
2. **Performance** - Zero-cost abstractions and efficient execution
3. **Developer Experience** - Clean, readable code with helpful error messages
4. **Real-time First** - Built-in WebSocket support for modern applications

## Core Components

### Request/Response Cycle

```
Client Request
     ↓
┌─────────────────────┐
│   Handler Chain     │
│  ┌───────────────┐  │
│  │   Rescuer     │  │  ← Catches exceptions
│  ├───────────────┤  │
│  │   Logger      │  │  ← Logs requests
│  ├───────────────┤  │
│  │   Auth        │  │  ← Authentication
│  ├───────────────┤  │
│  │   Router      │  │  ← Route matching
│  └───────────────┘  │
└─────────────────────┘
           ↓
┌─────────────────────┐
│      Endpoint       │
│  ┌───────────────┐  │
│  │   Request     │──┼──→ Parse & Validate
│  ├───────────────┤  │
│  │   call()      │──┼──→ Business Logic
│  ├───────────────┤  │
│  │   Response    │──┼──→ Serialize Output
│  └───────────────┘  │
└─────────────────────┘
           ↓
    Client Response
```

### Component Diagram

```
┌──────────────────────────────────────────────────────┐
│                         Azu                          │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  Endpoints  │  │  Channels   │  │  Components │  │
│  │             │  │             │  │             │  │
│  │  HTTP       │  │  WebSocket  │  │  Live UI    │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  │
│         │                │                │         │
│         └────────────────┼────────────────┘         │
│                          │                          │
│  ┌───────────────────────┴───────────────────────┐  │
│  │                    Router                      │  │
│  │                  (Radix Tree)                  │  │
│  └───────────────────────┬───────────────────────┘  │
│                          │                          │
│  ┌───────────────────────┴───────────────────────┐  │
│  │               Handler Pipeline                 │  │
│  │  Rescuer → Logger → CORS → Auth → Static      │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
├──────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │    Cache    │  │  Templates  │  │   Config    │  │
│  │   Memory/   │  │   Crinja    │  │ Environment │  │
│  │   Redis     │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
└──────────────────────────────────────────────────────┘
```

## Type-Safe Request Handling

Azu uses generics to ensure type safety throughout the request lifecycle:

```crystal
struct UserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)
  #                     ↑                  ↑
  #                     Input Type         Output Type
```

The compiler verifies:
- Request data matches the expected shape
- Response type is correctly returned
- All code paths return the correct type

## Handler Pipeline

Handlers form a middleware chain that processes every request:

```crystal
MyApp.start [
  Azu::Handler::Rescuer.new,  # 1. Handle errors
  Azu::Handler::Logger.new,   # 2. Log requests
  AuthHandler.new,             # 3. Authenticate
  RateLimitHandler.new,        # 4. Rate limit
  MyEndpoint.new,              # 5. Handle request
]
```

Each handler can:
- Process the request before passing it on
- Modify the response after it returns
- Short-circuit the chain (e.g., for authentication failures)

## Routing

The router uses a radix tree for O(k) route matching:

```
          /users
         /      \
       GET     POST
       /          \
   /:id          /
    /
  GET
```

Features:
- Static and dynamic route segments
- Wildcard matching
- HTTP method routing
- Path parameter extraction

## Real-Time Architecture

### WebSocket Channels

Channels handle persistent WebSocket connections:

```
Client 1 ←──┐
            │
Client 2 ←──┼──→ Channel ──→ Application Logic
            │
Client 3 ←──┘
```

### Live Components

Components maintain state on the server and push updates to clients:

```
┌─────────────────┐     WebSocket     ┌─────────────────┐
│                 │ ←────────────────→│                 │
│  Browser DOM    │                   │  Server State   │
│                 │ ←── HTML Patches  │                 │
└─────────────────┘                   └─────────────────┘
```

## Module Structure

```
Azu
├── Core           # Configuration, startup
├── Endpoint       # Request handling
├── Request        # Input contracts
├── Response       # Output contracts
├── Channel        # WebSocket handling
├── Component      # Live components
├── Spark          # Component system
├── Cache          # Caching stores
├── Router         # Route matching
├── Handler        # Middleware
└── Templates      # HTML rendering
```

## Performance Characteristics

| Component | Optimization |
|-----------|-------------|
| Router | Radix tree, path caching |
| Templates | Pre-compiled, cached |
| Components | Object pooling |
| Handlers | Zero-allocation hot path |

## See Also

- [Request Lifecycle](request-lifecycle.md)
- [Type Safety](type-safety.md)
- [Performance Design](performance-design.md)

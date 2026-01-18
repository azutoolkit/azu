# Quick Start Guide

Get up and running with Azu in 5 minutes! This guide will help you create your first Azu application and understand the core concepts.

## Prerequisites

- Crystal 0.35.0 or later
- Basic familiarity with Crystal syntax

## Step 1: Create a New Project

Create a new directory for your project:

```bash
mkdir my-azu-app
cd my-azu-app
```

Initialize a new Crystal project:

```bash
crystal init app my_azu_app
```

## Step 2: Add Azu Dependency

Add Azu to your `shard.yml`:

```yaml
dependencies:
  azu:
    github: your-org/azu
    version: ~> 0.5.26
```

Install dependencies:

```bash
shards install
```

## Step 3: Create Your First Endpoint

Create `src/endpoints/hello_endpoint.cr`:

```crystal
require "azu"

module MyAzuApp
  struct HelloRequest
    include Azu::Request

    @name : String
    getter name

    def initialize(@name : String = "World")
    end

    validate name, presence: true
  end

  struct HelloResponse
    include Azu::Response

    def initialize(@name : String)
    end

    def render
      {message: "Hello, #{@name}!", timestamp: Time.utc}
    end
  end

  struct HelloEndpoint
    include Azu::Endpoint(HelloRequest, HelloResponse)

    get "/hello"
    get "/hello/:name"

    def call : HelloResponse
      HelloResponse.new(hello_request.name)
    end
  end
end
```

## Step 4: Create Your Application

Create `src/my_azu_app.cr`:

```crystal
require "azu"
require "./endpoints/hello_endpoint"

module MyAzuApp
  include Azu

  # Configure your application
  configure do |config|
    config.host = "0.0.0.0"
    config.port = 3000
    config.env = "development"
  end

  # Define routes
  router do
    root :web, HelloEndpoint

    routes :web, "/api" do
      get "/hello", HelloEndpoint
      get "/hello/:name", HelloEndpoint
    end
  end
end
```

## Step 5: Run Your Application

Start your server:

```bash
crystal run src/my_azu_app.cr
```

You should see output like:

```
Server started at Mon 01/01/2024 12:00:00.
   ⤑  Environment: development
   ⤑  Host: 0.0.0.0
   ⤑  Port: 3000
   ⤑  Startup Time: 45 millis
```

## Step 6: Test Your Endpoints

Open your browser or use curl to test:

```bash
# Test the root endpoint
curl http://localhost:3000/

# Test with a name parameter
curl http://localhost:3000/api/hello/Alice

# Test the direct endpoint
curl http://localhost:3000/api/hello
```

You should see JSON responses like:

```json
{
  "message": "Hello, Alice!",
  "timestamp": "2024-01-01T12:00:00Z"
}
```

## What You've Built

Congratulations! You've created a fully functional Azu application with:

- **Type-safe endpoints** that validate input and structure output
- **Request contracts** that ensure data integrity
- **Response objects** that format your data consistently
- **Routing** that maps URLs to your endpoints
- **Configuration** that's easy to modify

## Key Concepts You've Learned

### Endpoints

Endpoints are the core of Azu applications. They define:

- What HTTP methods they handle (`get`, `post`, etc.)
- What data they accept (Request contracts)
- What data they return (Response objects)
- The business logic that connects them

### Request Contracts

Request contracts validate and type incoming data:

- Automatic validation using the Schema library
- Type safety for all parameters
- Clear error messages when validation fails

### Response Objects

Response objects structure your output:

- Consistent data formatting
- Type-safe serialization
- Easy to test and maintain

## Next Steps

Now that you have a working Azu application, explore these topics:

- **[Tutorial](tutorial.md)** - Build a more complete application
- **[Endpoints](fundamentals/endpoints.md)** - Deep dive into endpoint patterns
- **[Request Contracts](fundamentals/requests.md)** - Advanced validation techniques
- **[Response Objects](fundamentals/responses.md)** - Structured response handling
- **[Real-time Features](features/websockets.md)** - Add WebSocket support
- **[Templates](features/templates.md)** - Build HTML responses

## Common Patterns

### Adding More Endpoints

```crystal
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"
  post "/users"

  def call : UserResponse
    # Your logic here
  end
end
```

### Handling Different HTTP Methods

```crystal
struct ApiEndpoint
  include Azu::Endpoint(ApiRequest, ApiResponse)

  get "/api/data"
  post "/api/data"
  put "/api/data/:id"
  delete "/api/data/:id"

  def call : ApiResponse
    case context.request.method
    when "GET"
      handle_get
    when "POST"
      handle_post
    when "PUT"
      handle_put
    when "DELETE"
      handle_delete
    end
  end
end
```

### Error Handling

```crystal
def call : ApiResponse
  begin
    # Your logic here
    ApiResponse.new(data: result)
  rescue e
    error("Something went wrong", 500, e.message)
  end
end
```

## Troubleshooting

### Common Issues

**Port already in use:**

```bash
# Kill any process using port 3000
lsof -ti:3000 | xargs kill -9
```

**Dependency issues:**

```bash
# Clean and reinstall
rm -rf lib/
shards install
```

**Compilation errors:**

- Check that all required modules are included
- Verify that request/response types match your endpoint definition
- Ensure all dependencies are properly installed

## What's Next?

Ready to build something more substantial? Check out the [Tutorial](tutorial.md) to build a complete application with database integration, authentication, and real-time features!

---

_You're now ready to start building amazing applications with Azu! 🚀_

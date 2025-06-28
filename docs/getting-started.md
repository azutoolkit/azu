# Getting Started

Welcome to Azu! This guide will get you up and running with a type-safe, high-performance web application in under 10 minutes.

## What You'll Build

By the end of this guide, you'll have:

- ✅ A working Azu application with type-safe endpoints
- ✅ Request validation and structured error handling
- ✅ Real-time WebSocket functionality
- ✅ Template rendering with hot reloading
- ✅ Understanding of Azu's core concepts

## Prerequisites

Before starting, ensure you have:

- **Crystal 0.35.0+** installed ([installation guide](https://crystal-lang.org/install/))
- **Basic Crystal knowledge** (variables, classes, modules)
- **HTTP concepts** (requests, responses, status codes)

### Verify Your Crystal Installation

```bash
crystal version
# Should output: Crystal 1.x.x
```

## Installation

### 1. Create a New Project

```bash
mkdir my-azu-app
cd my-azu-app
```

### 2. Initialize Crystal Project

```bash
crystal init app my-azu-app
cd my-azu-app
```

### 3. Add Azu to Dependencies

Edit your `shard.yml`:

```yaml
name: my-azu-app
version: 0.1.0

authors:
  - Your Name <you@example.com>

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.2

crystal: >= 0.35.0

license: MIT
```

### 4. Install Dependencies

```bash
shards install
```

## Your First Application

Let's build a simple API that manages users with type-safe request/response contracts.

### 1. Create the Main Application File

Create `src/my-azu-app.cr`:

```crystal
require "azu"

# Application module with configuration
module MyAzuApp
  include Azu

  configure do
    # Environment-specific settings
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")

    # Template configuration
    templates.path = ["templates"]
    template_hot_reload = env.development?
  end
end

# Request contract - defines what we expect from client
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  # Type-safe initialization
  def initialize(@name = "", @email = "", @age = nil)
  end

  # Compile-time validation rules
  validate name, presence: true, length: {min: 2, max: 50}
  validate email, presence: true, format: /@/
  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true
end

# Response contract - defines what we return to client
struct UserResponse
  include Azu::Response

  def initialize(@user : User)
  end

  def render
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      age: @user.age,
      created_at: @user.created_at.to_rfc3339
    }.to_json
  end
end

# Simple User model for demonstration
class User
  property id : Int64
  property name : String
  property email : String
  property age : Int32?
  property created_at : Time

  @@next_id = 1_i64
  @@users = [] of User

  def initialize(@name : String, @email : String, @age : Int32? = nil)
    @id = @@next_id
    @@next_id += 1
    @created_at = Time.utc
    @@users << self
  end

  def self.all
    @@users
  end

  def self.find(id : Int64)
    @@users.find { |u| u.id == id }
  end
end

# Type-safe endpoint with explicit contracts
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Automatic request validation
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Safe to use validated data
    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    status 201
    UserResponse.new(user)
  end
end

# List users endpoint
struct ListUsersRequest
  include Azu::Request
end

struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    {
      users: @users.map do |user|
        {
          id: user.id,
          name: user.name,
          email: user.email,
          age: user.age,
          created_at: user.created_at.to_rfc3339
        }
      end,
      count: @users.size
    }.to_json
  end
end

struct ListUsersEndpoint
  include Azu::Endpoint(ListUsersRequest, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    users = User.all
    UsersListResponse.new(users)
  end
end

# Start the application with middleware stack
MyAzuApp.start [
  Azu::Handler::RequestId.new,    # Request tracking
  Azu::Handler::Rescuer.new,      # Error handling
  Azu::Handler::Logger.new,       # Request logging
  Azu::Handler::CORS.new,         # CORS headers
]
```

### 2. Run Your Application

```bash
crystal run src/my-azu-app.cr
```

You should see output like:

```
Server started at Mon 12/04/2023 10:30:45.
   ⤑  Environment: development
   ⤑  Host: 0.0.0.0
   ⤑  Port: 4000
   ⤑  Startup Time: 12.34 millis
```

### 3. Test Your API

**Create a user:**

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Smith", "email": "alice@example.com", "age": 30}'
```

**Response:**

```json
{
  "id": 1,
  "name": "Alice Smith",
  "email": "alice@example.com",
  "age": 30,
  "created_at": "2023-12-04T15:30:45Z"
}
```

**List users:**

```bash
curl http://localhost:4000/users
```

**Response:**

```json
{
  "users": [
    {
      "id": 1,
      "name": "Alice Smith",
      "email": "alice@example.com",
      "age": 30,
      "created_at": "2023-12-04T15:30:45Z"
    }
  ],
  "count": 1
}
```

## Adding Real-Time Features

Let's add WebSocket support for real-time user notifications.

### 1. Create a WebSocket Channel

Add to your `src/my-azu-app.cr`:

```crystal
# WebSocket channel for real-time notifications
class UserNotificationChannel < Azu::Channel
  SUBSCRIBERS = Set(HTTP::WebSocket).new

  ws "/notifications"

  def on_connect
    SUBSCRIBERS << socket.not_nil!

    # Send connection confirmation
    send_message({
      type: "connected",
      message: "Welcome to user notifications!",
      timestamp: Time.utc.to_rfc3339
    })

    Log.info { "WebSocket connected. Total subscribers: #{SUBSCRIBERS.size}" }
  end

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      case data["type"]?.try(&.as_s)
      when "ping"
        send_message({type: "pong", timestamp: Time.utc.to_rfc3339})
      else
        send_message({type: "error", message: "Unknown message type"})
      end
    rescue JSON::ParseException
      send_message({type: "error", message: "Invalid JSON"})
    end
  end

  def on_close(code, message)
    SUBSCRIBERS.delete(socket)
    Log.info { "WebSocket disconnected. Total subscribers: #{SUBSCRIBERS.size}" }
  end

  # Broadcast to all connected clients
  def self.broadcast_user_created(user : User)
    message = {
      type: "user_created",
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        age: user.age
      },
      timestamp: Time.utc.to_rfc3339
    }

    SUBSCRIBERS.each do |socket|
      spawn socket.send(message.to_json)
    end
  end

  private def send_message(data)
    socket.not_nil!.send(data.to_json)
  end
end
```

### 2. Update CreateUserEndpoint

Modify the `CreateUserEndpoint` to broadcast notifications:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    # Broadcast to WebSocket subscribers
    UserNotificationChannel.broadcast_user_created(user)

    status 201
    UserResponse.new(user)
  end
end
```

### 3. Test WebSocket Connection

Create a simple HTML client (`test_websocket.html`):

```html
<!DOCTYPE html>
<html>
  <head>
    <title>Azu WebSocket Test</title>
  </head>
  <body>
    <h1>User Notifications</h1>
    <div id="messages"></div>
    <button onclick="sendPing()">Send Ping</button>

    <script>
      const ws = new WebSocket("ws://localhost:4000/notifications");
      const messages = document.getElementById("messages");

      ws.onopen = function () {
        addMessage("Connected to server");
      };

      ws.onmessage = function (event) {
        const data = JSON.parse(event.data);
        addMessage(`${data.type}: ${JSON.stringify(data)}`);
      };

      ws.onclose = function () {
        addMessage("Disconnected from server");
      };

      function sendPing() {
        ws.send(JSON.stringify({ type: "ping" }));
      }

      function addMessage(text) {
        const div = document.createElement("div");
        div.textContent = `${new Date().toLocaleTimeString()}: ${text}`;
        messages.appendChild(div);
      }
    </script>
  </body>
</html>
```

Open this file in your browser, then create a user via the API to see real-time notifications!

## Error Handling

Azu provides comprehensive error handling out of the box. Let's test it:

### 1. Test Validation Errors

```bash
# Missing required fields
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response:**

```json
{
  "Status": "Unprocessable Entity",
  "Title": "Validation Error",
  "Detail": "The request could not be processed due to validation errors.",
  "FieldErrors": {
    "name": ["is required"],
    "email": ["is required"]
  },
  "ErrorId": "err_abc123",
  "Fingerprint": "validation_error_abc",
  "Timestamp": "2023-12-04T15:35:12Z"
}
```

### 2. Test Invalid Data

```bash
# Invalid email and age
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Bob", "email": "invalid-email", "age": -5}'
```

**Response:**

```json
{
  "Status": "Unprocessable Entity",
  "Title": "Validation Error",
  "Detail": "The request could not be processed due to validation errors.",
  "FieldErrors": {
    "email": ["is invalid"],
    "age": ["must be greater than 0"]
  },
  "ErrorId": "err_def456",
  "Fingerprint": "validation_error_def",
  "Timestamp": "2023-12-04T15:36:30Z"
}
```

## Project Structure

Your project should now look like this:

```
my-azu-app/
├── shard.yml
├── shard.lock
├── src/
│   └── my-azu-app.cr
├── spec/
└── test_websocket.html
```

For larger applications, organize your code like this:

```
my-azu-app/
├── shard.yml
├── src/
│   ├── my-azu-app.cr          # Main application file
│   ├── models/                # Data models
│   │   └── user.cr
│   ├── requests/              # Request contracts
│   │   ├── create_user_request.cr
│   │   └── list_users_request.cr
│   ├── responses/             # Response objects
│   │   ├── user_response.cr
│   │   └── users_list_response.cr
│   ├── endpoints/             # Endpoint handlers
│   │   ├── create_user_endpoint.cr
│   │   └── list_users_endpoint.cr
│   └── channels/              # WebSocket channels
│       └── user_notification_channel.cr
├── templates/                 # Template files
│   └── users/
│       └── show.html
└── spec/                      # Tests
    └── my-azu-app_spec.cr
```

## Configuration

Azu supports environment-specific configuration:

```crystal
module MyAzuApp
  include Azu

  configure do
    # Server settings
    host = ENV.fetch("HOST", "0.0.0.0")
    port = ENV.fetch("PORT", "4000").to_i

    # SSL configuration (production)
    if env.production?
      ssl_cert = ENV["SSL_CERT"]?
      ssl_key = ENV["SSL_KEY"]?
    end

    # Template settings
    templates.path = ["templates", "views"]
    template_hot_reload = env.development?

    # File upload limits
    upload.max_file_size = 10.megabytes
    upload.temp_dir = ENV.fetch("UPLOAD_DIR", "/tmp/uploads")

    # Logging configuration
    log.level = env.production? ? Log::Severity::INFO : Log::Severity::DEBUG
  end
end
```

## Next Steps

Congratulations! You've built a complete Azu application with:

- ✅ Type-safe HTTP endpoints
- ✅ Request validation and error handling
- ✅ Real-time WebSocket functionality
- ✅ Structured responses

### Where to Go Next:

1. **[Core Concepts →](core-concepts.md)** - Deep dive into endpoints, requests, and responses
2. **[Real-Time Features →](real-time.md)** - Master WebSocket channels and live components
3. **[Templates →](templates.md)** - Learn about the template engine and markup DSL
4. **[Middleware →](middleware.md)** - Add authentication, rate limiting, and custom handlers
5. **[Testing →](testing.md)** - Write comprehensive tests for your application

### Learn More:

- **[Architecture →](architecture.md)** - Understand Azu's design principles
- **[Performance →](performance.md)** - Optimize your application for scale
- **[API Reference →](api-reference.md)** - Complete API documentation

---

**Need Help?** Check the [FAQ & Troubleshooting](faq.md) section or join our community discussions.

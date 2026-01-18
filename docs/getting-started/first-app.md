# Your First Application

Build a complete, working Azu application from scratch. This guide will walk you through creating a user management API with type-safe endpoints, validation, and real-time features.

## What You'll Build

By the end of this guide, you'll have a fully functional application with:

- ✅ **Type-safe API endpoints** for user management
- ✅ **Request validation** with detailed error messages
- ✅ **Real-time notifications** via WebSocket
- ✅ **Template rendering** with hot reloading
- ✅ **Comprehensive error handling**

## Project Setup

### 1. Create Project Structure

```bash
# Create project directory
mkdir user-manager
cd user-manager

# Initialize Crystal project
crystal init app user_manager
cd user_manager
```

### 2. Add Dependencies

Edit `shard.yml`:

```yaml
name: user_manager
version: 0.1.0

authors:
  - Your Name <you@example.com>

dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.26

crystal: >= 0.35.0

license: MIT
```

Install dependencies:

```bash
shards install
```

### 3. Create Project Structure

```bash
# Create directories for organized code
mkdir -p src/{models,requests,responses,endpoints,channels}
mkdir -p templates/users
mkdir -p public/css
```

## Building the Application

### Step 1: Define the User Model

Create `src/models/user.cr`:

```crystal
# Simple in-memory user model for demonstration
class User
  property id : Int64
  property name : String
  property email : String
  property age : Int32?
  property created_at : Time
  property updated_at : Time

  @@next_id = 1_i64
  @@users = [] of User

  def initialize(@name : String, @email : String, @age : Int32? = nil)
    @id = @@next_id
    @@next_id += 1
    @created_at = Time.utc
    @updated_at = Time.utc
    @@users << self
  end

  def self.all : Array(User)
    @@users.dup
  end

  def self.find(id : Int64) : User?
    @@users.find { |u| u.id == id }
  end

  def self.find_by_email(email : String) : User?
    @@users.find { |u| u.email == email }
  end

  def update(name : String? = nil, email : String? = nil, age : Int32? = nil)
    @name = name if name
    @email = email if email
    @age = age if age
    @updated_at = Time.utc
  end

  def delete
    @@users.delete(self)
  end

  def to_json(json : JSON::Builder)
    json.object do
      json.field "id", @id
      json.field "name", @name
      json.field "email", @email
      json.field "age", @age
      json.field "created_at", @created_at.to_rfc3339
      json.field "updated_at", @updated_at.to_rfc3339
    end
  end
end
```

### Step 2: Create Request Contracts

Create `src/requests/create_user_request.cr`:

```crystal
struct CreateUserRequest
  include Azu::Request

  getter name : String
  getter email : String
  getter age : Int32?

  def initialize(@name = "", @email = "", @age = nil)
  end

  # Validation rules
  validate name, presence: true, length: {min: 2, max: 50},
    message: "Name must be between 2 and 50 characters"

  validate email, presence: true, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i,
    message: "Email must be a valid email address"

  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true,
    message: "Age must be between 1 and 150"
end
```

Create `src/requests/update_user_request.cr`:

```crystal
struct UpdateUserRequest
  include Azu::Request

  getter name : String?
  getter email : String?
  getter age : Int32?

  def initialize(@name = nil, @email = nil, @age = nil)
  end

  # Validation rules
  validate name, length: {min: 2, max: 50}, allow_nil: true,
    message: "Name must be between 2 and 50 characters"

  validate email, format: /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, allow_nil: true,
    message: "Email must be a valid email address"

  validate age, numericality: {greater_than: 0, less_than: 150}, allow_nil: true,
    message: "Age must be between 1 and 150"
end
```

### Step 3: Create Response Objects

Create `src/responses/user_response.cr`:

```crystal
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
      created_at: @user.created_at.to_rfc3339,
      updated_at: @user.updated_at.to_rfc3339
    }.to_json
  end
end
```

Create `src/responses/users_list_response.cr`:

```crystal
struct UsersListResponse
  include Azu::Response

  def initialize(@users : Array(User))
  end

  def render
    {
      users: @users.map { |user| user_json(user) },
      count: @users.size,
      timestamp: Time.utc.to_rfc3339
    }.to_json
  end

  private def user_json(user : User)
    {
      id: user.id,
      name: user.name,
      email: user.email,
      age: user.age,
      created_at: user.created_at.to_rfc3339
    }
  end
end
```

### Step 4: Create Endpoints

Create `src/endpoints/create_user_endpoint.cr`:

```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(CreateUserRequest, UserResponse)

  post "/users"

  def call : UserResponse
    # Validate request
    unless create_user_request.valid?
      raise Azu::Response::ValidationError.new(
        create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check for duplicate email
    if User.find_by_email(create_user_request.email)
      raise Azu::Response::ValidationError.new(
        {"email" => ["Email is already taken"]}
      )
    end

    # Create user
    user = User.new(
      name: create_user_request.name,
      email: create_user_request.email,
      age: create_user_request.age
    )

    # Broadcast to WebSocket subscribers
    UserNotificationChannel.broadcast_user_created(user)

    # Set response status and return
    status 201
    UserResponse.new(user)
  end
end
```

Create `src/endpoints/list_users_endpoint.cr`:

```crystal
struct ListUsersEndpoint
  include Azu::Endpoint(EmptyRequest, UsersListResponse)

  get "/users"

  def call : UsersListResponse
    users = User.all
    UsersListResponse.new(users)
  end
end
```

Create `src/endpoints/show_user_endpoint.cr`:

```crystal
struct ShowUserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    if user = User.find(user_id)
      UserResponse.new(user)
    else
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end
  end
end
```

Create `src/endpoints/update_user_endpoint.cr`:

```crystal
struct UpdateUserEndpoint
  include Azu::Endpoint(UpdateUserRequest, UserResponse)

  put "/users/:id"

  def call : UserResponse
    user_id = params["id"].to_i64

    unless user = User.find(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    # Validate request
    unless update_user_request.valid?
      raise Azu::Response::ValidationError.new(
        update_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
      )
    end

    # Check for duplicate email if updating
    if email = update_user_request.email
      if existing_user = User.find_by_email(email)
        unless existing_user.id == user_id
          raise Azu::Response::ValidationError.new(
            {"email" => ["Email is already taken"]}
          )
        end
      end
    end

    # Update user
    user.update(
      name: update_user_request.name,
      email: update_user_request.email,
      age: update_user_request.age
    )

    # Broadcast update
    UserNotificationChannel.broadcast_user_updated(user)

    UserResponse.new(user)
  end
end
```

Create `src/endpoints/delete_user_endpoint.cr`:

```crystal
struct DeleteUserEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Empty)

  delete "/users/:id"

  def call : Azu::Response::Empty
    user_id = params["id"].to_i64

    unless user = User.find(user_id)
      raise Azu::Response::NotFound.new("/users/#{user_id}")
    end

    # Broadcast deletion
    UserNotificationChannel.broadcast_user_deleted(user)

    # Delete user
    user.delete

    status 204
    Azu::Response::Empty.new
  end
end
```

### Step 5: Create WebSocket Channel

Create `src/channels/user_notification_channel.cr`:

```crystal
class UserNotificationChannel < Azu::Channel
  CONNECTIONS = Set(HTTP::WebSocket).new

  ws "/notifications"

  def on_connect
    CONNECTIONS << socket.not_nil!

    send_to_client({
      type: "connected",
      message: "Connected to user notifications",
      timestamp: Time.utc.to_rfc3339
    })

    Log.info { "User connected. Total connections: #{CONNECTIONS.size}" }
  end

  def on_message(message : String)
    begin
      data = JSON.parse(message)
      case data["type"]?.try(&.as_s)
      when "ping"
        send_to_client({type: "pong", timestamp: Time.utc.to_rfc3339})
      when "subscribe"
        send_to_client({type: "subscribed", message: "Subscribed to notifications"})
      else
        send_to_client({type: "error", message: "Unknown message type"})
      end
    rescue JSON::ParseException
      send_to_client({type: "error", message: "Invalid JSON"})
    end
  end

  def on_close(code, message)
    CONNECTIONS.delete(socket)
    Log.info { "User disconnected. Total connections: #{CONNECTIONS.size}" }
  end

  # Broadcast user created event
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

    broadcast_to_all(message)
  end

  # Broadcast user updated event
  def self.broadcast_user_updated(user : User)
    message = {
      type: "user_updated",
      user: {
        id: user.id,
        name: user.name,
        email: user.email,
        age: user.age
      },
      timestamp: Time.utc.to_rfc3339
    }

    broadcast_to_all(message)
  end

  # Broadcast user deleted event
  def self.broadcast_user_deleted(user : User)
    message = {
      type: "user_deleted",
      user_id: user.id,
      timestamp: Time.utc.to_rfc3339
    }

    broadcast_to_all(message)
  end

  private def self.broadcast_to_all(message)
    CONNECTIONS.each do |socket|
      spawn socket.send(message.to_json)
    end
  end

  private def send_to_client(data)
    socket.not_nil!.send(data.to_json)
  end
end
```

### Step 6: Create Templates

Create `templates/users/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>User Manager</title>
    <style>
      body {
        font-family: Arial, sans-serif;
        margin: 20px;
      }
      .user-card {
        border: 1px solid #ddd;
        padding: 15px;
        margin: 10px 0;
        border-radius: 5px;
      }
      .user-form {
        margin: 20px 0;
        padding: 20px;
        background: #f9f9f9;
        border-radius: 5px;
      }
      .form-group {
        margin: 10px 0;
      }
      label {
        display: block;
        margin-bottom: 5px;
      }
      input,
      button {
        padding: 8px;
        margin: 5px;
      }
      .error {
        color: red;
      }
      .success {
        color: green;
      }
      #notifications {
        margin: 20px 0;
        padding: 10px;
        background: #e8f5e8;
        border-radius: 5px;
      }
    </style>
  </head>
  <body>
    <h1>User Manager</h1>

    <div id="notifications">
      <h3>Real-time Notifications</h3>
      <div id="notification-messages"></div>
    </div>

    <div class="user-form">
      <h2>Create New User</h2>
      <form id="create-user-form">
        <div class="form-group">
          <label for="name">Name:</label>
          <input type="text" id="name" name="name" required />
        </div>
        <div class="form-group">
          <label for="email">Email:</label>
          <input type="email" id="email" name="email" required />
        </div>
        <div class="form-group">
          <label for="age">Age:</label>
          <input type="number" id="age" name="age" min="1" max="150" />
        </div>
        <button type="submit">Create User</button>
      </form>
    </div>

    <div id="users-list">
      <h2>Users</h2>
      <div id="users-container"></div>
    </div>

    <script>
      // WebSocket connection
      const ws = new WebSocket("ws://localhost:4000/notifications");
      const notificationMessages = document.getElementById(
        "notification-messages"
      );
      const usersContainer = document.getElementById("users-container");

      ws.onopen = function () {
        addNotification("Connected to server");
        ws.send(JSON.stringify({ type: "subscribe" }));
      };

      ws.onmessage = function (event) {
        const data = JSON.parse(event.data);
        handleNotification(data);
      };

      ws.onclose = function () {
        addNotification("Disconnected from server");
      };

      function addNotification(message) {
        const div = document.createElement("div");
        div.textContent = `${new Date().toLocaleTimeString()}: ${message}`;
        notificationMessages.appendChild(div);
      }

      function handleNotification(data) {
        switch (data.type) {
          case "user_created":
            addNotification(
              `User created: ${data.user.name} (${data.user.email})`
            );
            loadUsers();
            break;
          case "user_updated":
            addNotification(`User updated: ${data.user.name}`);
            loadUsers();
            break;
          case "user_deleted":
            addNotification(`User deleted: ID ${data.user_id}`);
            loadUsers();
            break;
          case "connected":
          case "subscribed":
            addNotification(data.message);
            break;
        }
      }

      // Form submission
      document
        .getElementById("create-user-form")
        .addEventListener("submit", async function (e) {
          e.preventDefault();

          const formData = new FormData(e.target);
          const userData = {
            name: formData.get("name"),
            email: formData.get("email"),
            age: formData.get("age") ? parseInt(formData.get("age")) : null,
          };

          try {
            const response = await fetch("/users", {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
              },
              body: JSON.stringify(userData),
            });

            if (response.ok) {
              const user = await response.json();
              addNotification(`User created successfully: ${user.name}`);
              e.target.reset();
              loadUsers();
            } else {
              const error = await response.json();
              addNotification(`Error: ${error.Detail}`);
            }
          } catch (error) {
            addNotification(`Error: ${error.message}`);
          }
        });

      // Load users
      async function loadUsers() {
        try {
          const response = await fetch("/users");
          const data = await response.json();

          usersContainer.innerHTML = "";
          data.users.forEach((user) => {
            const userCard = document.createElement("div");
            userCard.className = "user-card";
            userCard.innerHTML = `
                        <h3>${user.name}</h3>
                        <p><strong>Email:</strong> ${user.email}</p>
                        <p><strong>Age:</strong> ${
                          user.age || "Not specified"
                        }</p>
                        <p><strong>Created:</strong> ${new Date(
                          user.created_at
                        ).toLocaleString()}</p>
                        <button onclick="deleteUser(${user.id})">Delete</button>
                    `;
            usersContainer.appendChild(userCard);
          });
        } catch (error) {
          addNotification(`Error loading users: ${error.message}`);
        }
      }

      async function deleteUser(id) {
        if (confirm("Are you sure you want to delete this user?")) {
          try {
            const response = await fetch(`/users/${id}`, {
              method: "DELETE",
            });

            if (response.ok) {
              addNotification("User deleted successfully");
              loadUsers();
            } else {
              addNotification("Error deleting user");
            }
          } catch (error) {
            addNotification(`Error: ${error.message}`);
          }
        }
      }

      // Load users on page load
      loadUsers();
    </script>
  </body>
</html>
```

### Step 7: Create Main Application

Create `src/user_manager.cr`:

```crystal
require "azu"

# Load all application files
require "./models/*"
require "./requests/*"
require "./responses/*"
require "./endpoints/*"
require "./channels/*"

module UserManager
  include Azu

  configure do
    # Server configuration
    port = ENV.fetch("PORT", "4000").to_i
    host = ENV.fetch("HOST", "0.0.0.0")

    # Template configuration
    templates.path = ["templates"]
    template_hot_reload = env.development?

    # Upload configuration
    upload.max_file_size = 10.megabytes
    upload.temp_dir = "/tmp/uploads"

    # Logging
    log.level = env.development? ? Log::Severity::DEBUG : Log::Severity::INFO
  end
end

# HTML endpoint for the main page
struct HomeEndpoint
  include Azu::Endpoint(EmptyRequest, Azu::Response::Text)
  include Azu::Templates::Renderable

  get "/"

  def call
    view "users/index.html", {
      title: "User Manager",
      users: User.all
    }
  end
end

# Start the application
UserManager.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
  Azu::Handler::CORS.new,
  Azu::Handler::Static.new("public"),
  HomeEndpoint.new,
]
```

## Running Your Application

### 1. Start the Server

```bash
# Run the application
crystal run src/user_manager.cr
```

You should see:

```
Server started at Mon 12/04/2023 10:30:45.
   ⤑  Environment: development
   ⤑  Host: 0.0.0.0
   ⤑  Port: 4000
   ⤑  Startup Time: 12.34 millis
```

### 2. Test the API

#### Create a User

```bash
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Alice Smith",
    "email": "alice@example.com",
    "age": 30
  }'
```

**Response:**

```json
{
  "id": 1,
  "name": "Alice Smith",
  "email": "alice@example.com",
  "age": 30,
  "created_at": "2023-12-04T15:30:45Z",
  "updated_at": "2023-12-04T15:30:45Z"
}
```

#### List Users

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
  "count": 1,
  "timestamp": "2023-12-04T15:30:45Z"
}
```

#### Get a Specific User

```bash
curl http://localhost:4000/users/1
```

#### Update a User

```bash
curl -X PUT http://localhost:4000/users/1 \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Alice Johnson",
    "age": 31
  }'
```

#### Delete a User

```bash
curl -X DELETE http://localhost:4000/users/1
```

### 3. Test the Web Interface

Open your browser and navigate to `http://localhost:4000`. You'll see:

- A form to create new users
- A list of all users
- Real-time notifications when users are created, updated, or deleted

### 4. Test WebSocket Notifications

Open the browser console and watch for real-time notifications when you:

- Create a new user via the form
- Delete a user via the API
- Update a user via the API

## Testing Error Handling

### Test Validation Errors

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
    "name": ["Name must be between 2 and 50 characters"],
    "email": ["Email must be a valid email address"]
  },
  "ErrorId": "err_abc123",
  "Fingerprint": "validation_error_abc",
  "Timestamp": "2023-12-04T15:35:12Z"
}
```

### Test Duplicate Email

```bash
# Try to create user with existing email
curl -X POST http://localhost:4000/users \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Bob Smith",
    "email": "alice@example.com",
    "age": 25
  }'
```

### Test Not Found

```bash
# Try to get non-existent user
curl http://localhost:4000/users/999
```

## Project Structure

Your completed project should look like:

```
user_manager/
├── shard.yml
├── shard.lock
├── src/
│   ├── user_manager.cr          # Main application
│   ├── models/
│   │   └── user.cr             # User model
│   ├── requests/
│   │   ├── create_user_request.cr
│   │   └── update_user_request.cr
│   ├── responses/
│   │   ├── user_response.cr
│   │   └── users_list_response.cr
│   ├── endpoints/
│   │   ├── create_user_endpoint.cr
│   │   ├── list_users_endpoint.cr
│   │   ├── show_user_endpoint.cr
│   │   ├── update_user_endpoint.cr
│   │   └── delete_user_endpoint.cr
│   └── channels/
│       └── user_notification_channel.cr
├── templates/
│   └── users/
│       └── index.html
├── public/
│   └── css/
└── spec/
```

## Next Steps

Congratulations! You've built a complete Azu application. Here's what to explore next:

1. **[Configuration →](configuration.md)** - Learn about advanced configuration options
2. **[Core Concepts →](../core-concepts.md)** - Deep dive into endpoints, requests, and responses
3. **[Real-Time Features →](../real-time.md)** - Master WebSocket channels and live components
4. **[Templates →](../templates.md)** - Learn about template rendering and markup DSL
5. **[Testing →](../testing.md)** - Write comprehensive tests for your application

## Extending Your Application

Consider adding these features:

- **Database integration** with PostgreSQL or MySQL
- **Authentication and authorization**
- **File uploads** for user avatars
- **Pagination** for the users list
- **Search and filtering** capabilities
- **Email notifications** when users are created
- **API rate limiting**
- **Request logging and monitoring**

---

**Your first Azu application is complete!** You now have a solid foundation for building more complex applications with type safety, real-time features, and excellent developer experience.

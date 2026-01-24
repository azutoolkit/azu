# Testing Your App

This tutorial teaches you how to write comprehensive tests for your Azu application, including endpoints, models, and WebSocket channels.

## What You'll Learn

By the end of this tutorial, you'll be able to:

- Set up a testing environment
- Write unit tests for endpoints
- Test request validation
- Test database models
- Test WebSocket channels

## Prerequisites

- Completed previous tutorials
- Basic understanding of testing concepts

## Step 1: Test Setup

Create `spec/spec_helper.cr`:

```crystal
require "spec"
require "../src/user_api"

# Test configuration
module TestConfig
  def self.setup
    # Use test database
    ENV["DATABASE_URL"] = "sqlite3://./test.db"
    ENV["AZU_ENV"] = "test"
  end
end

# Helper module for creating test contexts
module TestHelpers
  def create_context(
    method : String = "GET",
    path : String = "/",
    body : String? = nil,
    headers : HTTP::Headers = HTTP::Headers.new
  ) : HTTP::Server::Context
    io = IO::Memory.new
    request = HTTP::Request.new(method, path, headers, body)
    response = HTTP::Server::Response.new(io)
    HTTP::Server::Context.new(request, response)
  end

  def json_headers : HTTP::Headers
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json"
    headers
  end

  def parse_response(context : HTTP::Server::Context) : JSON::Any
    context.response.close
    body = context.response.@io.as(IO::Memory).to_s
    JSON.parse(body.split("\r\n\r\n").last)
  end
end

# Setup before all tests
TestConfig.setup

Spec.before_each do
  # Clean database before each test
  User.delete_all if defined?(User)
end
```

## Step 2: Testing Endpoints

Create `spec/endpoints/create_user_endpoint_spec.cr`:

```crystal
require "../spec_helper"

describe CreateUserEndpoint do
  include TestHelpers

  describe "#call" do
    it "creates a user with valid data" do
      body = {
        name: "Alice Smith",
        email: "alice@example.com",
        age: 30
      }.to_json

      context = create_context("POST", "/users", body, json_headers)
      endpoint = CreateUserEndpoint.new

      # Simulate the request
      endpoint.context = context
      response = endpoint.call

      response.should be_a(UserResponse)
      context.response.status_code.should eq(201)
    end

    it "returns validation error for missing name" do
      body = {email: "alice@example.com"}.to_json
      context = create_context("POST", "/users", body, json_headers)
      endpoint = CreateUserEndpoint.new
      endpoint.context = context

      expect_raises(Azu::Response::ValidationError) do
        endpoint.call
      end
    end

    it "returns validation error for invalid email" do
      body = {name: "Alice", email: "invalid-email"}.to_json
      context = create_context("POST", "/users", body, json_headers)
      endpoint = CreateUserEndpoint.new
      endpoint.context = context

      expect_raises(Azu::Response::ValidationError) do
        endpoint.call
      end
    end

    it "returns validation error for duplicate email" do
      # Create first user
      User.create!(name: "First", email: "alice@example.com")

      body = {name: "Second", email: "alice@example.com"}.to_json
      context = create_context("POST", "/users", body, json_headers)
      endpoint = CreateUserEndpoint.new
      endpoint.context = context

      expect_raises(Azu::Response::ValidationError) do
        endpoint.call
      end
    end
  end
end
```

Create `spec/endpoints/show_user_endpoint_spec.cr`:

```crystal
require "../spec_helper"

describe ShowUserEndpoint do
  include TestHelpers

  describe "#call" do
    it "returns user when found" do
      user = User.create!(name: "Alice", email: "alice@example.com")

      context = create_context("GET", "/users/#{user.id}")
      endpoint = ShowUserEndpoint.new
      endpoint.context = context
      endpoint.params = {"id" => user.id.to_s}

      response = endpoint.call

      response.should be_a(UserResponse)
    end

    it "raises NotFound for non-existent user" do
      context = create_context("GET", "/users/999")
      endpoint = ShowUserEndpoint.new
      endpoint.context = context
      endpoint.params = {"id" => "999"}

      expect_raises(Azu::Response::NotFound) do
        endpoint.call
      end
    end
  end
end
```

## Step 3: Testing Request Validation

Create `spec/requests/create_user_request_spec.cr`:

```crystal
require "../spec_helper"

describe CreateUserRequest do
  describe "validation" do
    it "validates with correct data" do
      request = CreateUserRequest.new(
        name: "Alice Smith",
        email: "alice@example.com",
        age: 30
      )

      request.valid?.should be_true
      request.errors.should be_empty
    end

    it "requires name" do
      request = CreateUserRequest.new(
        name: "",
        email: "alice@example.com"
      )

      request.valid?.should be_false
      request.errors.map(&.field).should contain("name")
    end

    it "validates name length" do
      request = CreateUserRequest.new(
        name: "A",  # Too short
        email: "alice@example.com"
      )

      request.valid?.should be_false
    end

    it "requires email" do
      request = CreateUserRequest.new(
        name: "Alice Smith",
        email: ""
      )

      request.valid?.should be_false
      request.errors.map(&.field).should contain("email")
    end

    it "validates email format" do
      request = CreateUserRequest.new(
        name: "Alice Smith",
        email: "invalid-email"
      )

      request.valid?.should be_false
    end

    it "allows nil age" do
      request = CreateUserRequest.new(
        name: "Alice Smith",
        email: "alice@example.com",
        age: nil
      )

      request.valid?.should be_true
    end

    it "validates age range" do
      request = CreateUserRequest.new(
        name: "Alice Smith",
        email: "alice@example.com",
        age: 200  # Too old
      )

      request.valid?.should be_false
    end
  end
end
```

## Step 4: Testing Models

Create `spec/models/user_spec.cr`:

```crystal
require "../spec_helper"

describe User do
  describe "validations" do
    it "requires name" do
      user = User.new(email: "test@example.com")
      user.valid?.should be_false
      user.errors.should contain("name")
    end

    it "validates name length" do
      user = User.new(name: "A", email: "test@example.com")
      user.valid?.should be_false
    end

    it "requires email" do
      user = User.new(name: "Test User")
      user.valid?.should be_false
    end
  end

  describe "CRUD operations" do
    it "creates a user" do
      user = User.create!(name: "Test", email: "test@example.com")

      user.id.should_not be_nil
      user.name.should eq("Test")
      user.created_at.should_not be_nil
    end

    it "finds a user by ID" do
      created = User.create!(name: "Test", email: "test@example.com")
      found = User.find?(created.id.not_nil!)

      found.should_not be_nil
      found.try(&.name).should eq("Test")
    end

    it "updates a user" do
      user = User.create!(name: "Test", email: "test@example.com")
      user.update!(name: "Updated")

      User.find?(user.id.not_nil!).try(&.name).should eq("Updated")
    end

    it "deletes a user" do
      user = User.create!(name: "Test", email: "test@example.com")
      user.destroy!

      User.find?(user.id.not_nil!).should be_nil
    end
  end

  describe "scopes" do
    it "filters active users" do
      User.create!(name: "Active", email: "active@example.com", active: true)
      User.create!(name: "Inactive", email: "inactive@example.com", active: false)

      active_users = User.active.all
      active_users.size.should eq(1)
      active_users.first.name.should eq("Active")
    end

    it "orders by recent" do
      first = User.create!(name: "First", email: "first@example.com")
      sleep 0.1.seconds
      second = User.create!(name: "Second", email: "second@example.com")

      users = User.recent.all
      users.first.name.should eq("Second")
    end
  end
end
```

## Step 5: Testing WebSocket Channels

Create `spec/channels/notification_channel_spec.cr`:

```crystal
require "../spec_helper"

describe NotificationChannel do
  describe "#on_connect" do
    it "adds socket to connections" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new

      initial_count = NotificationChannel::CONNECTIONS.size
      channel.socket = socket
      channel.on_connect

      NotificationChannel::CONNECTIONS.size.should eq(initial_count + 1)
    end

    it "sends welcome message" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      socket.sent_messages.size.should eq(1)
      message = JSON.parse(socket.sent_messages.first)
      message["type"].should eq("connected")
    end
  end

  describe "#on_message" do
    it "responds to ping with pong" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      channel.on_message(%({"type": "ping"}))

      messages = socket.sent_messages
      pong = messages.find { |m| JSON.parse(m)["type"] == "pong" }
      pong.should_not be_nil
    end

    it "handles invalid JSON" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      channel.on_message("invalid json")

      messages = socket.sent_messages
      error = messages.find { |m| JSON.parse(m)["type"] == "error" }
      error.should_not be_nil
    end
  end

  describe "#on_close" do
    it "removes socket from connections" do
      channel = NotificationChannel.new
      socket = MockWebSocket.new
      channel.socket = socket
      channel.on_connect

      count_before = NotificationChannel::CONNECTIONS.size
      channel.on_close(nil, nil)

      NotificationChannel::CONNECTIONS.size.should eq(count_before - 1)
    end
  end
end

# Mock WebSocket for testing
class MockWebSocket
  getter sent_messages = [] of String

  def send(message : String)
    @sent_messages << message
  end

  def object_id
    0_u64
  end
end
```

## Step 6: Integration Tests

Create `spec/integration/api_spec.cr`:

```crystal
require "../spec_helper"
require "http/client"

describe "User API Integration" do
  # Start server before tests
  before_all do
    spawn do
      UserAPI.start
    end
    sleep 1.second  # Wait for server to start
  end

  it "creates and retrieves a user" do
    # Create user
    response = HTTP::Client.post(
      "http://localhost:4000/users",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: "Integration Test", email: "integration@test.com"}.to_json
    )

    response.status_code.should eq(201)
    user = JSON.parse(response.body)
    user["name"].should eq("Integration Test")

    # Retrieve user
    get_response = HTTP::Client.get("http://localhost:4000/users/#{user["id"]}")
    get_response.status_code.should eq(200)
  end

  it "lists all users" do
    response = HTTP::Client.get("http://localhost:4000/users")

    response.status_code.should eq(200)
    data = JSON.parse(response.body)
    data["users"].as_a.should be_a(Array(JSON::Any))
  end

  it "returns 404 for non-existent user" do
    response = HTTP::Client.get("http://localhost:4000/users/999999")

    response.status_code.should eq(404)
  end

  it "validates request data" do
    response = HTTP::Client.post(
      "http://localhost:4000/users",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: {name: ""}.to_json
    )

    response.status_code.should eq(422)
  end
end
```

## Step 7: Running Tests

Run all tests:

```bash
crystal spec
```

Run specific test file:

```bash
crystal spec spec/endpoints/create_user_endpoint_spec.cr
```

Run with verbose output:

```bash
crystal spec --verbose
```

Run focused tests:

```bash
crystal spec --tag focus
```

## Test Organization

```
spec/
├── spec_helper.cr           # Test configuration
├── endpoints/               # Endpoint tests
│   ├── create_user_endpoint_spec.cr
│   ├── show_user_endpoint_spec.cr
│   └── ...
├── requests/                # Request validation tests
│   ├── create_user_request_spec.cr
│   └── ...
├── models/                  # Model tests
│   └── user_spec.cr
├── channels/                # WebSocket channel tests
│   └── notification_channel_spec.cr
└── integration/             # Integration tests
    └── api_spec.cr
```

## Best Practices

1. **Test one thing per test** - Each test should verify one specific behavior
2. **Use descriptive names** - Test names should describe the expected behavior
3. **Clean up after tests** - Reset database state between tests
4. **Mock external services** - Don't call real external APIs in tests
5. **Test edge cases** - Include tests for error conditions and boundary values

## Key Concepts Learned

### Test Structure

```crystal
describe ClassName do
  describe "#method" do
    it "does something" do
      # Arrange
      # Act
      # Assert
    end
  end
end
```

### Common Assertions

```crystal
value.should eq(expected)
value.should be_true
value.should be_nil
value.should_not be_nil
array.should contain(item)
expect_raises(ErrorClass) { code }
```

## Next Steps

You've learned to test your Azu application. Continue with:

- [Deploying to Production](deploying-to-production.md) - Deploy your tested app

---

**Your tests are ready!** You now have comprehensive test coverage for your application.

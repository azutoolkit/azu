# Integration Testing

Comprehensive guide to integration testing in Azu applications, focusing on testing component interactions and end-to-end workflows.

## Overview

Integration testing verifies that different components of your Azu application work together correctly. This guide covers testing complete request-response cycles, database interactions, and multi-step workflows.

## Integration Test Setup

### Test Environment Configuration

```crystal
# spec/integration/spec_helper.cr
require "../spec_helper"

# Integration test configuration
CONFIG.integration = {
  database_url: "postgresql://localhost/azu_integration_test",
  redis_url: "redis://localhost:6379/1",
  environment: "integration"
}

# Integration test utilities
module IntegrationHelpers
  def self.setup_test_database
    # Create test database schema
    DB.connect(CONFIG.integration.database_url) do |db|
      db.exec("CREATE TABLE IF NOT EXISTS users (id SERIAL PRIMARY KEY, name VARCHAR, email VARCHAR)")
      db.exec("CREATE TABLE IF NOT EXISTS posts (id SERIAL PRIMARY KEY, title VARCHAR, user_id INTEGER)")
    end
  end

  def self.cleanup_test_database
    # Clean test data
    DB.connect(CONFIG.integration.database_url) do |db|
      db.exec("TRUNCATE TABLE posts CASCADE")
      db.exec("TRUNCATE TABLE users CASCADE")
    end
  end

  def self.create_test_app
    # Create test application instance
    ExampleApp.new([
      Azu::Handler::Rescuer.new,
      Azu::Handler::Logger.new,
      Azu::Handler::CORS.new
    ])
  end
end
```

### Test Application Setup

```crystal
# spec/integration/test_app.cr
class TestApp
  include Azu::Application

  def initialize
    super([
      Azu::Handler::Rescuer.new,
      Azu::Handler::Logger.new,
      Azu::Handler::CORS.new
    ])

    # Register test endpoints
    register_routes
  end

  private def register_routes
    UserEndpoint.get "/users/:id"
    UserEndpoint.post "/users"
    PostEndpoint.get "/posts"
    PostEndpoint.post "/posts"
  end
end
```

## End-to-End Testing

### Complete Request-Response Testing

```crystal
# spec/integration/endpoints/user_workflow_spec.cr
require "./spec_helper"

describe "User Workflow Integration" do
  describe "user creation and retrieval" do
    it "creates user and retrieves it" do
      # Setup
      app = IntegrationHelpers.create_test_app

      # Step 1: Create user
      create_response = app.post("/users", {
        "name" => "John Doe",
        "email" => "john@example.com"
      })

      create_response.status.should eq(201)
      user_id = JSON.parse(create_response.body)["id"].as_i

      # Step 2: Retrieve user
      get_response = app.get("/users/#{user_id}")

      get_response.status.should eq(200)
      user_data = JSON.parse(get_response.body)
      user_data["name"].should eq("John Doe")
      user_data["email"].should eq("john@example.com")
    end
  end
end
```

### Multi-Step Workflow Testing

```crystal
# spec/integration/workflows/user_post_workflow_spec.cr
describe "User-Post Workflow" do
  it "handles complete user and post creation workflow" do
    app = IntegrationHelpers.create_test_app

    # Step 1: Create user
    user_response = app.post("/users", {
      "name" => "Jane Doe",
      "email" => "jane@example.com"
    })

    user_id = JSON.parse(user_response.body)["id"].as_i

    # Step 2: Create post for user
    post_response = app.post("/posts", {
      "title" => "My First Post",
      "content" => "This is my first post content",
      "user_id" => user_id
    })

    post_response.status.should eq(201)
    post_id = JSON.parse(post_response.body)["id"].as_i

    # Step 3: Verify post appears in user's posts
    posts_response = app.get("/users/#{user_id}/posts")

    posts_response.status.should eq(200)
    posts = JSON.parse(posts_response.body)["posts"].as_a
    posts.size.should eq(1)
    posts[0]["title"].should eq("My First Post")
  end
end
```

## Database Integration Testing

### Database Transaction Testing

```crystal
# spec/integration/database/transaction_spec.cr
describe "Database Transactions" do
  it "rolls back failed transactions" do
    app = IntegrationHelpers.create_test_app

    # Attempt to create user with invalid data
    response = app.post("/users", {
      "name" => "", # Invalid: empty name
      "email" => "invalid-email" # Invalid: malformed email
    })

    response.status.should eq(422)

    # Verify no user was created in database
    db = DB.connect(CONFIG.integration.database_url)
    user_count = db.scalar("SELECT COUNT(*) FROM users WHERE email = ?", "invalid-email")
    user_count.should eq(0)
  end

  it "commits successful transactions" do
    app = IntegrationHelpers.create_test_app

    # Create valid user
    response = app.post("/users", {
      "name" => "Valid User",
      "email" => "valid@example.com"
    })

    response.status.should eq(201)

    # Verify user exists in database
    db = DB.connect(CONFIG.integration.database_url)
    user = db.query_one?("SELECT * FROM users WHERE email = ?", "valid@example.com", as: User)
    user.should_not be_nil
    user.name.should eq("Valid User")
  end
end
```

### Database Relationship Testing

```crystal
# spec/integration/database/relationships_spec.cr
describe "Database Relationships" do
  it "maintains referential integrity" do
    app = IntegrationHelpers.create_test_app

    # Create user
    user_response = app.post("/users", {
      "name" => "Test User",
      "email" => "test@example.com"
    })

    user_id = JSON.parse(user_response.body)["id"].as_i

    # Create post with valid user_id
    post_response = app.post("/posts", {
      "title" => "Test Post",
      "user_id" => user_id
    })

    post_response.status.should eq(201)

    # Attempt to create post with invalid user_id
    invalid_post_response = app.post("/posts", {
      "title" => "Invalid Post",
      "user_id" => 99999 # Non-existent user
    })

    invalid_post_response.status.should eq(422)
  end
end
```

## API Integration Testing

### RESTful API Testing

```crystal
# spec/integration/api/restful_spec.cr
describe "RESTful API Integration" do
  it "implements full CRUD operations" do
    app = IntegrationHelpers.create_test_app

    # CREATE
    create_response = app.post("/users", {
      "name" => "CRUD User",
      "email" => "crud@example.com"
    })

    create_response.status.should eq(201)
    user_id = JSON.parse(create_response.body)["id"].as_i

    # READ
    read_response = app.get("/users/#{user_id}")
    read_response.status.should eq(200)
    user_data = JSON.parse(read_response.body)
    user_data["name"].should eq("CRUD User")

    # UPDATE
    update_response = app.put("/users/#{user_id}", {
      "name" => "Updated CRUD User",
      "email" => "updated@example.com"
    })

    update_response.status.should eq(200)

    # Verify update
    verify_response = app.get("/users/#{user_id}")
    updated_data = JSON.parse(verify_response.body)
    updated_data["name"].should eq("Updated CRUD User")

    # DELETE
    delete_response = app.delete("/users/#{user_id}")
    delete_response.status.should eq(204)

    # Verify deletion
    not_found_response = app.get("/users/#{user_id}")
    not_found_response.status.should eq(404)
  end
end
```

### API Error Handling Testing

```crystal
# spec/integration/api/error_handling_spec.cr
describe "API Error Handling" do
  it "handles various error scenarios" do
    app = IntegrationHelpers.create_test_app

    # Test 404 for non-existent resource
    not_found_response = app.get("/users/99999")
    not_found_response.status.should eq(404)

    # Test 422 for validation errors
    invalid_response = app.post("/users", {
      "name" => "",
      "email" => "invalid"
    })

    invalid_response.status.should eq(422)
    errors = JSON.parse(invalid_response.body)["errors"]
    errors.should contain("name is required")
    errors.should contain("email must be a valid email address")

    # Test 500 for server errors
    # (This would require mocking a service to throw an exception)
  end
end
```

## Authentication Integration Testing

### Session Management Testing

```crystal
# spec/integration/auth/session_spec.cr
describe "Session Management" do
  it "maintains session across requests" do
    app = IntegrationHelpers.create_test_app

    # Login
    login_response = app.post("/login", {
      "email" => "user@example.com",
      "password" => "password123"
    })

    login_response.status.should eq(200)
    session_cookie = login_response.headers["Set-Cookie"]

    # Access protected resource with session
    protected_response = app.get("/profile", headers: {
      "Cookie" => session_cookie
    })

    protected_response.status.should eq(200)

    # Access without session should fail
    unauthorized_response = app.get("/profile")
    unauthorized_response.status.should eq(401)
  end
end
```

### JWT Token Testing

```crystal
# spec/integration/auth/jwt_spec.cr
describe "JWT Authentication" do
  it "validates JWT tokens" do
    app = IntegrationHelpers.create_test_app

    # Get JWT token
    token_response = app.post("/auth/token", {
      "email" => "user@example.com",
      "password" => "password123"
    })

    token_response.status.should eq(200)
    token = JSON.parse(token_response.body)["token"].as_s

    # Use token for authenticated request
    auth_response = app.get("/api/protected", headers: {
      "Authorization" => "Bearer #{token}"
    })

    auth_response.status.should eq(200)

    # Test with invalid token
    invalid_response = app.get("/api/protected", headers: {
      "Authorization" => "Bearer invalid-token"
    })

    invalid_response.status.should eq(401)
  end
end
```

## File Upload Integration Testing

### Multipart File Upload Testing

```crystal
# spec/integration/uploads/file_upload_spec.cr
describe "File Upload Integration" do
  it "handles file uploads correctly" do
    app = IntegrationHelpers.create_test_app

    # Create test file
    test_file = File.tempfile("test_upload") do |file|
      file.puts("This is test content")
    end

    # Upload file
    upload_response = app.post("/uploads", {
      "file" => test_file.path,
      "description" => "Test upload"
    })

    upload_response.status.should eq(201)
    upload_data = JSON.parse(upload_response.body)
    upload_data["filename"].should eq("test_upload")

    # Verify file was saved
    saved_file_path = upload_data["path"].as_s
    File.exists?(saved_file_path).should be_true

    # Cleanup
    File.delete(test_file.path)
  end
end
```

## Cache Integration Testing

### Redis Cache Testing

```crystal
# spec/integration/cache/redis_spec.cr
describe "Redis Cache Integration" do
  it "caches and retrieves data" do
    app = IntegrationHelpers.create_test_app

    # First request - should hit database
    first_response = app.get("/users/1")
    first_response.status.should eq(200)

    # Second request - should hit cache
    second_response = app.get("/users/1")
    second_response.status.should eq(200)

    # Verify cache headers
    second_response.headers["X-Cache"].should eq("HIT")

    # Verify response times (cached should be faster)
    # This would require timing the requests
  end
end
```

## Background Job Integration Testing

### Job Queue Testing

```crystal
# spec/integration/jobs/job_queue_spec.cr
describe "Background Job Integration" do
  it "processes background jobs" do
    app = IntegrationHelpers.create_test_app

    # Enqueue job
    job_response = app.post("/jobs/email", {
      "to" => "user@example.com",
      "subject" => "Test Email",
      "body" => "This is a test email"
    })

    job_response.status.should eq(202)
    job_id = JSON.parse(job_response.body)["job_id"].as_s

    # Wait for job processing
    sleep(1)

    # Check job status
    status_response = app.get("/jobs/#{job_id}")
    status_response.status.should eq(200)
    job_status = JSON.parse(status_response.body)["status"]
    job_status.should eq("completed")
  end
end
```

## Performance Integration Testing

### Load Testing Integration

```crystal
# spec/integration/performance/load_spec.cr
describe "Performance Integration" do
  it "handles concurrent requests" do
    app = IntegrationHelpers.create_test_app

    # Create multiple concurrent requests
    responses = [] of HTTP::Client::Response

    spawn do
      10.times do |i|
        response = app.get("/users/#{i + 1}")
        responses << response
      end
    end

    # Wait for all requests to complete
    sleep(2)

    # Verify all requests succeeded
    responses.each do |response|
      response.status.should eq(200)
    end
  end
end
```

## Test Data Management

### Test Data Setup

```crystal
# spec/integration/helpers/test_data.cr
module TestData
  def self.setup_test_users
    db = DB.connect(CONFIG.integration.database_url)

    users = [
      {name: "Test User 1", email: "user1@example.com"},
      {name: "Test User 2", email: "user2@example.com"},
      {name: "Test User 3", email: "user3@example.com"}
    ]

    users.each do |user_data|
      db.exec("INSERT INTO users (name, email) VALUES (?, ?)",
              user_data[:name], user_data[:email])
    end
  end

  def self.cleanup_test_data
    db = DB.connect(CONFIG.integration.database_url)
    db.exec("TRUNCATE TABLE posts CASCADE")
    db.exec("TRUNCATE TABLE users CASCADE")
  end
end
```

### Test Isolation

```crystal
# spec/integration/spec_helper.cr
Spec.before_each do
  # Setup fresh test data for each test
  TestData.setup_test_users
end

Spec.after_each do
  # Cleanup after each test
  TestData.cleanup_test_data
end
```

## Running Integration Tests

### Test Commands

```bash
# Run all integration tests
crystal spec spec/integration/

# Run specific integration test file
crystal spec spec/integration/endpoints/user_workflow_spec.cr

# Run integration tests with database setup
crystal spec spec/integration/ -- --integration

# Run integration tests in parallel (be careful with database)
crystal spec spec/integration/ --parallel
```

### CI/CD Integration

```yaml
# .github/workflows/integration-tests.yml
name: Integration Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  integration-tests:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:13
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: azu_integration_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

      redis:
        image: redis:6
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v3
      - name: Setup Crystal
        uses: crystal-lang/install-crystal@v1
      - name: Install dependencies
        run: shards install
      - name: Run integration tests
        run: crystal spec spec/integration/
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost:5432/azu_integration_test
          REDIS_URL: redis://localhost:6379/1
```

## Best Practices

### 1. Test Realistic Scenarios

```crystal
# Test realistic user workflows
describe "Realistic User Journey" do
  it "completes full user registration and first post" do
    app = IntegrationHelpers.create_test_app

    # 1. User registers
    register_response = app.post("/register", {
      "name" => "New User",
      "email" => "newuser@example.com",
      "password" => "securepassword"
    })

    # 2. User logs in
    login_response = app.post("/login", {
      "email" => "newuser@example.com",
      "password" => "securepassword"
    })

    # 3. User creates first post
    post_response = app.post("/posts", {
      "title" => "My First Post",
      "content" => "Hello, world!"
    })

    # 4. User views their profile
    profile_response = app.get("/profile")

    # Verify all steps worked
    register_response.status.should eq(201)
    login_response.status.should eq(200)
    post_response.status.should eq(201)
    profile_response.status.should eq(200)
  end
end
```

### 2. Test Error Scenarios

```crystal
# Test error handling in integration
describe "Error Handling Integration" do
  it "handles database connection failures gracefully" do
    # Mock database failure
    Database.stub(:connect, raise DatabaseConnectionError.new) do
      app = IntegrationHelpers.create_test_app

      response = app.get("/users/1")

      response.status.should eq(500)
      response.body.should contain("Database connection error")
    end
  end
end
```

### 3. Test Performance Boundaries

```crystal
# Test performance under load
describe "Performance Boundaries" do
  it "handles large payloads" do
    app = IntegrationHelpers.create_test_app

    # Create large payload
    large_content = "x" * 1000000 # 1MB content

    response = app.post("/posts", {
      "title" => "Large Post",
      "content" => large_content
    })

    response.status.should eq(413) # Payload Too Large
  end
end
```

## Next Steps

- [Unit Testing](unit.md) - Test individual components
- [WebSocket Testing](websockets.md) - Test real-time features
- [Testing Best Practices](testing.md) - General testing guidelines

---

_Integration tests ensure that your components work together correctly and catch issues that unit tests might miss._

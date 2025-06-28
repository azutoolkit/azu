# Unit Testing

Comprehensive guide to unit testing Azu applications, endpoints, and components.

## Overview

Unit testing in Azu focuses on testing individual components in isolation. This guide covers testing endpoints, request/response objects, and utility functions with Crystal's built-in testing framework.

## Testing Framework Setup

### Basic Test Structure

```crystal
# spec/unit/endpoint_spec.cr
require "../spec_helper"

describe "UserEndpoint" do
  describe "#call" do
    it "returns user data for valid request" do
      # Test implementation
    end

    it "returns error for invalid user id" do
      # Test implementation
    end
  end
end
```

### Test Configuration

```crystal
# spec/spec_helper.cr
require "spec"
require "../src/azu"

# Test configuration
CONFIG.test = {
  database_url: "sqlite3://./test.db",
  log_level: "error",
  environment: "test"
}

# Test utilities
module TestHelpers
  def self.create_test_request(path : String, method : String = "GET", params : Hash = {} of String => String)
    Azu::HttpRequest.new(
      method: method,
      path: path,
      params: params,
      headers: HTTP::Headers.new
    )
  end

  def self.create_test_response(status : Int32 = 200, body : String = "")
    Azu::Response.new(status: status, body: body)
  end
end
```

## Endpoint Testing

### Basic Endpoint Test

```crystal
# spec/unit/endpoints/user_endpoint_spec.cr
require "../spec_helper"

describe UserEndpoint do
  describe "#call" do
    it "returns user data" do
      # Arrange
      request = TestHelpers.create_test_request("/users/1")
      user_endpoint = UserEndpoint.new(request)

      # Act
      response = user_endpoint.call

      # Assert
      response.should be_a(UserResponse)
      response.status.should eq(200)
      response.data.should_not be_nil
    end

    it "returns 404 for non-existent user" do
      # Arrange
      request = TestHelpers.create_test_request("/users/999")
      user_endpoint = UserEndpoint.new(request)

      # Act
      response = user_endpoint.call

      # Assert
      response.status.should eq(404)
    end
  end
end
```

### Testing with Mock Data

```crystal
# spec/unit/endpoints/user_endpoint_spec.cr
describe UserEndpoint do
  describe "with mock user service" do
    it "uses mocked user data" do
      # Arrange
      mock_user = User.new(id: 1, name: "Test User", email: "test@example.com")
      UserService.stub(:find, mock_user) do
        request = TestHelpers.create_test_request("/users/1")
        user_endpoint = UserEndpoint.new(request)

        # Act
        response = user_endpoint.call

        # Assert
        response.data.name.should eq("Test User")
      end
    end
  end
end
```

### Testing Different HTTP Methods

```crystal
# spec/unit/endpoints/user_endpoint_spec.cr
describe UserEndpoint do
  describe "HTTP methods" do
    it "handles GET requests" do
      request = TestHelpers.create_test_request("/users/1", "GET")
      user_endpoint = UserEndpoint.new(request)

      response = user_endpoint.call
      response.status.should eq(200)
    end

    it "handles POST requests" do
      request = TestHelpers.create_test_request("/users", "POST", {
        "name" => "New User",
        "email" => "new@example.com"
      })
      user_endpoint = UserEndpoint.new(request)

      response = user_endpoint.call
      response.status.should eq(201)
    end

    it "rejects unsupported methods" do
      request = TestHelpers.create_test_request("/users/1", "DELETE")
      user_endpoint = UserEndpoint.new(request)

      expect_raises(Azu::MethodNotAllowedError) do
        user_endpoint.call
      end
    end
  end
end
```

## Request/Response Testing

### Request Validation Testing

```crystal
# spec/unit/requests/user_request_spec.cr
describe UserRequest do
  describe "validation" do
    it "validates required fields" do
      # Valid request
      valid_params = {"name" => "John Doe", "email" => "john@example.com"}
      request = UserRequest.new(valid_params)

      request.valid?.should be_true
      request.errors.should be_empty
    end

    it "rejects missing required fields" do
      # Invalid request
      invalid_params = {"name" => "John Doe"} # missing email
      request = UserRequest.new(invalid_params)

      request.valid?.should be_false
      request.errors.should contain("email is required")
    end

    it "validates email format" do
      invalid_params = {"name" => "John Doe", "email" => "invalid-email"}
      request = UserRequest.new(invalid_params)

      request.valid?.should be_false
      request.errors.should contain("email must be a valid email address")
    end
  end
end
```

### Response Testing

```crystal
# spec/unit/responses/user_response_spec.cr
describe UserResponse do
  describe "rendering" do
    it "renders JSON correctly" do
      user = User.new(id: 1, name: "Test User", email: "test@example.com")
      response = UserResponse.new(user)

      json = response.to_json
      parsed = JSON.parse(json)

      parsed["id"].should eq(1)
      parsed["name"].should eq("Test User")
      parsed["email"].should eq("test@example.com")
    end

    it "renders HTML correctly" do
      user = User.new(id: 1, name: "Test User", email: "test@example.com")
      response = UserResponse.new(user)

      html = response.to_html
      html.should contain("Test User")
      html.should contain("test@example.com")
    end
  end
end
```

## Component Testing

### Live Component Testing

```crystal
# spec/unit/components/user_list_component_spec.cr
describe UserListComponent do
  describe "rendering" do
    it "renders user list" do
      users = [
        User.new(id: 1, name: "User 1"),
        User.new(id: 2, name: "User 2")
      ]

      component = UserListComponent.new(users: users)
      html = component.render

      html.should contain("User 1")
      html.should contain("User 2")
    end

    it "handles empty user list" do
      component = UserListComponent.new(users: [] of User)
      html = component.render

      html.should contain("No users found")
    end
  end

  describe "events" do
    it "handles user selection" do
      component = UserListComponent.new(users: [User.new(id: 1, name: "Test User")])

      result = component.on_event("user_selected", {"user_id" => "1"})

      result.should be_a(Component::EventResult)
      result.action.should eq("update_selection")
    end
  end
end
```

## Utility Function Testing

### Helper Method Testing

```crystal
# spec/unit/utils/string_utils_spec.cr
describe StringUtils do
  describe ".slugify" do
    it "converts spaces to hyphens" do
      StringUtils.slugify("Hello World").should eq("hello-world")
    end

    it "removes special characters" do
      StringUtils.slugify("Hello, World!").should eq("hello-world")
    end

    it "handles multiple spaces" do
      StringUtils.slugify("Hello   World").should eq("hello-world")
    end

    it "handles empty string" do
      StringUtils.slugify("").should eq("")
    end
  end

  describe ".truncate" do
    it "truncates long strings" do
      long_string = "This is a very long string that needs to be truncated"
      result = StringUtils.truncate(long_string, 20)

      result.should eq("This is a very long...")
      result.size.should be <= 23 # 20 + "..."
    end

    it "doesn't truncate short strings" do
      short_string = "Short"
      result = StringUtils.truncate(short_string, 20)

      result.should eq("Short")
    end
  end
end
```

## Database Testing

### Model Testing

```crystal
# spec/unit/models/user_spec.cr
describe User do
  describe "validations" do
    it "validates presence of name" do
      user = User.new(email: "test@example.com")
      user.valid?.should be_false
      user.errors.should contain("name is required")
    end

    it "validates email format" do
      user = User.new(name: "Test User", email: "invalid-email")
      user.valid?.should be_false
      user.errors.should contain("email must be a valid email address")
    end
  end

  describe "associations" do
    it "has many posts" do
      user = User.create(name: "Test User", email: "test@example.com")
      post = Post.create(title: "Test Post", user_id: user.id)

      user.posts.should contain(post)
    end
  end
end
```

### Repository Testing

```crystal
# spec/unit/repositories/user_repository_spec.cr
describe UserRepository do
  describe "#find_by_email" do
    it "finds user by email" do
      user = User.create(name: "Test User", email: "test@example.com")

      found_user = UserRepository.find_by_email("test@example.com")

      found_user.should eq(user)
    end

    it "returns nil for non-existent email" do
      found_user = UserRepository.find_by_email("nonexistent@example.com")

      found_user.should be_nil
    end
  end
end
```

## Mocking and Stubbing

### Service Mocking

```crystal
# spec/unit/services/email_service_spec.cr
describe EmailService do
  describe "#send_welcome_email" do
    it "sends welcome email successfully" do
      # Mock external email service
      EmailProvider.stub(:send, true) do
        result = EmailService.send_welcome_email("user@example.com")

        result.should be_true
      end
    end

    it "handles email service failure" do
      EmailProvider.stub(:send, false) do
        result = EmailService.send_welcome_email("user@example.com")

        result.should be_false
      end
    end
  end
end
```

### Database Mocking

```crystal
# spec/unit/repositories/user_repository_spec.cr
describe UserRepository do
  describe "with mocked database" do
    it "uses mocked connection" do
      mock_connection = MockDatabaseConnection.new
      mock_connection.stub(:query_one, User.new(id: 1, name: "Mock User"))

      UserRepository.stub(:connection, mock_connection) do
        user = UserRepository.find(1)

        user.name.should eq("Mock User")
      end
    end
  end
end
```

## Test Data Factories

### Factory Pattern

```crystal
# spec/factories/user_factory.cr
class UserFactory
  def self.create(attributes : Hash = {} of String => String) : User
    default_attributes = {
      "name" => "Test User",
      "email" => "test@example.com",
      "password" => "password123"
    }

    merged_attributes = default_attributes.merge(attributes)

    User.create(merged_attributes)
  end

  def self.build(attributes : Hash = {} of String => String) : User
    default_attributes = {
      "name" => "Test User",
      "email" => "test@example.com",
      "password" => "password123"
    }

    merged_attributes = default_attributes.merge(attributes)

    User.new(merged_attributes)
  end
end

# Usage in tests
describe UserEndpoint do
  it "creates user with factory" do
    user = UserFactory.create({"name" => "John Doe"})

    user.name.should eq("John Doe")
    user.email.should eq("test@example.com")
  end
end
```

## Test Organization

### Test Structure

```crystal
# Recommended test file structure
spec/
├── unit/
│   ├── endpoints/
│   │   ├── user_endpoint_spec.cr
│   │   └── post_endpoint_spec.cr
│   ├── requests/
│   │   ├── user_request_spec.cr
│   │   └── post_request_spec.cr
│   ├── responses/
│   │   ├── user_response_spec.cr
│   │   └── post_response_spec.cr
│   ├── components/
│   │   └── user_list_component_spec.cr
│   ├── models/
│   │   └── user_spec.cr
│   ├── services/
│   │   └── email_service_spec.cr
│   └── utils/
│       └── string_utils_spec.cr
├── factories/
│   └── user_factory.cr
└── spec_helper.cr
```

### Test Naming Conventions

```crystal
# Use descriptive test names
describe UserEndpoint do
  describe "#call" do
    it "returns user data when user exists" do
      # Test implementation
    end

    it "returns 404 error when user does not exist" do
      # Test implementation
    end

    it "validates user id parameter" do
      # Test implementation
    end
  end

  describe "authentication" do
    it "requires valid authentication token" do
      # Test implementation
    end

    it "rejects expired tokens" do
      # Test implementation
    end
  end
end
```

## Running Tests

### Test Commands

```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/unit/endpoints/user_endpoint_spec.cr

# Run tests with verbose output
crystal spec --verbose

# Run tests with coverage
crystal spec --coverage

# Run tests in parallel
crystal spec --parallel
```

### Test Configuration

```crystal
# spec/spec_helper.cr
require "spec"

# Configure test environment
Spec.before_each do
  # Setup test database
  setup_test_database

  # Clear any cached data
  clear_cache
end

Spec.after_each do
  # Cleanup after each test
  cleanup_test_database
end
```

## Best Practices

### 1. Test Isolation

```crystal
# Each test should be independent
describe UserEndpoint do
  describe "#call" do
    it "does not affect other tests" do
      # Use unique test data
      user = UserFactory.create({"email" => "unique@example.com"})

      # Test implementation

      # Cleanup is automatic via before_each/after_each
    end
  end
end
```

### 2. Descriptive Assertions

```crystal
# Use descriptive assertions
describe UserEndpoint do
  it "validates user input" do
    request = TestHelpers.create_test_request("/users", "POST", {
      "email" => "invalid-email"
    })

    user_endpoint = UserEndpoint.new(request)
    response = user_endpoint.call

    # Descriptive assertions
    response.status.should eq(422)
    response.errors.should contain("email must be a valid email address")
  end
end
```

### 3. Test Coverage

```crystal
# Aim for high test coverage
describe UserEndpoint do
  describe "edge cases" do
    it "handles nil parameters" do
      # Test nil handling
    end

    it "handles empty parameters" do
      # Test empty parameter handling
    end

    it "handles malformed JSON" do
      # Test malformed input handling
    end
  end
end
```

## Next Steps

- [Integration Testing](integration.md) - Test component interactions
- [WebSocket Testing](websockets.md) - Test real-time features
- [Testing Best Practices](testing.md) - General testing guidelines

---

_Remember: Good unit tests are fast, isolated, and focused on a single unit of functionality._

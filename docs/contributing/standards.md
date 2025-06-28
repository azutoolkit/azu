# Code Standards

Comprehensive coding standards and guidelines for contributing to the Azu web framework.

## Overview

This document outlines the coding standards, conventions, and best practices that all contributors should follow when working on the Azu framework. Consistent code style and patterns ensure maintainability and readability.

## Crystal Language Standards

### Code Style Guidelines

#### Indentation and Formatting

```crystal
# Use 2 spaces for indentation
class ExampleClass
  def example_method
    if condition
      do_something
    else
      do_something_else
    end
  end
end

# Align method parameters for readability
def complex_method(
  param1 : String,
  param2 : Int32,
  param3 : Bool = false
)
  # Method implementation
end
```

#### Naming Conventions

```crystal
# Use snake_case for methods and variables
def calculate_user_score
  user_name = "john_doe"
  total_score = 0
end

# Use PascalCase for classes, structs, and modules
class UserManager
  struct UserData
  module DatabaseHelper
end

# Use UPPER_SNAKE_CASE for constants
MAX_RETRY_ATTEMPTS = 3
DEFAULT_TIMEOUT = 30.seconds
```

#### Type Annotations

```crystal
# Use explicit type annotations for public APIs
def create_user(name : String, email : String) : User
  User.new(name: name, email: email)
end

# Use type annotations for instance variables
class UserService
  @database : Database::Connection
  @cache : Cache::Store

  def initialize(@database, @cache)
  end
end
```

### Code Organization

#### File Structure

```crystal
# src/azu/handler/example_handler.cr
require "../http_request"
require "../response"

# Module documentation
module Azu
  # Handler documentation
  class ExampleHandler
    include Handler

    # Constants
    MAX_RETRIES = 3

    # Instance variables
    @retry_count : Int32

    # Constructor
    def initialize(@retry_count = 0)
    end

    # Public methods
    def call(request : HttpRequest, response : Response) : Response
      # Implementation
    end

    # Private methods
    private def handle_retry(request : HttpRequest) : Response
      # Implementation
    end
  end
end
```

#### Module Organization

```crystal
# Group related functionality in modules
module Azu
  # Core framework functionality
  module Core
    # Core classes and structs
  end

  # HTTP handling
  module Handler
    # Handler implementations
  end

  # Template system
  module Templates
    # Template-related classes
  end
end
```

## Azu Framework Standards

### Endpoint Patterns

```crystal
# Standard endpoint structure
struct UserEndpoint
  include Endpoint(UserRequest, UserResponse)

  # Route definitions
  get "/users/:id"
  post "/users"
  put "/users/:id"
  delete "/users/:id"

  # Implementation
  def call : UserResponse
    case @request.method
    when "GET"
      handle_get
    when "POST"
      handle_post
    when "PUT"
      handle_put
    when "DELETE"
      handle_delete
    else
      raise MethodNotAllowedError.new
    end
  end

  # Private handler methods
  private def handle_get : UserResponse
    user_id = @request.params["id"]
    user = User.find(user_id)
    UserResponse.new(user)
  end

  private def handle_post : UserResponse
    user = User.create(@request.data)
    UserResponse.new(user, status: 201)
  end
end
```

### Request/Response Patterns

```crystal
# Request contract
struct UserRequest
  include Request

  # Validations
  validates :name, presence: true, length: {min: 2, max: 50}
  validates :email, presence: true, format: :email
  validates :age, numericality: {greater_than: 0, less_than: 150}

  # Custom validations
  validate :email_domain_allowed

  private def email_domain_allowed
    return unless email?

    allowed_domains = ["example.com", "test.com"]
    domain = email.not_nil!.split("@").last?

    unless domain && allowed_domains.includes?(domain)
      errors.add(:email, "domain not allowed")
    end
  end
end

# Response contract
struct UserResponse
  include Response

  def initialize(@user : User, @status : Int32 = 200)
  end

  def render : String
    case @request.accept
    when "application/json"
      render_json
    when "text/html"
      render_html
    else
      render_json
    end
  end

  private def render_json : String
    {
      id: @user.id,
      name: @user.name,
      email: @user.email,
      created_at: @user.created_at
    }.to_json
  end

  private def render_html : String
    Templates.render("users/show.html", {user: @user})
  end
end
```

### Handler Patterns

```crystal
# Standard handler structure
class AuthenticationHandler
  include Handler

  def initialize(@secret_key : String)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Pre-processing
    token = extract_token(request)

    unless valid_token?(token)
      return Response.new(
        status: 401,
        body: {error: "Unauthorized"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
    end

    # Continue to next handler
    @next.call(request, response)
  rescue ex : Exception
    # Error handling
    handle_error(ex, request, response)
  end

  private def extract_token(request : HttpRequest) : String?
    request.headers["Authorization"]?.try(&.gsub("Bearer ", ""))
  end

  private def valid_token?(token : String?) : Bool
    return false unless token

    # Token validation logic
    JWT.decode(token, @secret_key, JWT::Algorithm::HS256)
    true
  rescue JWT::Error
    false
  end

  private def handle_error(ex : Exception, request : HttpRequest, response : Response) : Response
    Response.new(
      status: 500,
      body: {error: "Internal server error"}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end
end
```

## Documentation Standards

### Code Documentation

```crystal
# Class documentation
# Represents a user in the system with authentication and profile management capabilities.
#
# @example Basic usage
#   user = User.new(name: "John Doe", email: "john@example.com")
#   user.save
#
# @example With validation
#   user = User.new(name: "", email: "invalid-email")
#   unless user.valid?
#     puts user.errors.full_messages
#   end
class User
  # Creates a new user with the given attributes.
  #
  # @param name [String] The user's full name
  # @param email [String] The user's email address
  # @param password [String?] Optional password for authentication
  # @raise [ArgumentError] If name or email is empty
  def initialize(@name : String, @email : String, @password : String? = nil)
    raise ArgumentError.new("Name cannot be empty") if @name.empty?
    raise ArgumentError.new("Email cannot be empty") if @email.empty?
  end

  # Saves the user to the database.
  #
  # @return [Bool] true if saved successfully, false otherwise
  # @raise [DatabaseError] If database connection fails
  def save : Bool
    # Implementation
  end
end
```

### API Documentation

```crystal
# API endpoint documentation
# @api {get} /users/:id Get user by ID
# @apiName GetUser
# @apiGroup Users
# @apiVersion 1.0.0
#
# @apiParam {Number} id User's unique ID
#
# @apiSuccess {Object} user User object
# @apiSuccess {Number} user.id User ID
# @apiSuccess {String} user.name User's full name
# @apiSuccess {String} user.email User's email address
# @apiSuccess {String} user.created_at User creation timestamp
#
# @apiError {Object} 404 User not found
# @apiError {Object} 500 Internal server error
struct GetUserEndpoint
  include Endpoint(GetUserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    # Implementation
  end
end
```

## Testing Standards

### Test Structure

```crystal
# spec/azu/handler/example_handler_spec.cr
require "../spec_helper"

describe Azu::Handler::ExampleHandler do
  describe "#call" do
    it "processes valid requests" do
      # Arrange
      handler = Azu::Handler::ExampleHandler.new
      request = create_test_request("/test")
      response = create_test_response

      # Act
      result = handler.call(request, response)

      # Assert
      result.status.should eq(200)
    end

    it "handles invalid requests" do
      # Arrange
      handler = Azu::Handler::ExampleHandler.new
      request = create_test_request("/invalid")
      response = create_test_response

      # Act & Assert
      expect_raises(ArgumentError) do
        handler.call(request, response)
      end
    end

    it "maintains response headers" do
      # Arrange
      handler = Azu::Handler::ExampleHandler.new
      request = create_test_request("/test")
      response = create_test_response

      # Act
      result = handler.call(request, response)

      # Assert
      result.headers["Content-Type"].should eq("application/json")
    end
  end

  describe "edge cases" do
    it "handles nil parameters" do
      # Test nil handling
    end

    it "handles empty parameters" do
      # Test empty parameter handling
    end

    it "handles malformed data" do
      # Test malformed data handling
    end
  end
end
```

### Test Utilities

```crystal
# spec/support/test_helpers.cr
module TestHelpers
  def self.create_test_request(
    path : String,
    method : String = "GET",
    params : Hash = {} of String => String,
    headers : HTTP::Headers = HTTP::Headers.new
  ) : Azu::HttpRequest
    Azu::HttpRequest.new(
      method: method,
      path: path,
      params: params,
      headers: headers
    )
  end

  def self.create_test_response(
    status : Int32 = 200,
    body : String = "",
    headers : HTTP::Headers = HTTP::Headers.new
  ) : Azu::Response
    Azu::Response.new(
      status: status,
      body: body,
      headers: headers
    )
  end

  def self.create_test_user(attributes : Hash = {} of String => String) : User
    default_attributes = {
      "name" => "Test User",
      "email" => "test@example.com"
    }

    User.new(**default_attributes.merge(attributes))
  end
end
```

## Performance Standards

### Memory Management

```crystal
# Use appropriate data structures
class OptimizedHandler
  include Handler

  # Use Array for small collections
  @small_list = Array(String).new(10)

  # Use Set for large collections with lookups
  @large_set = Set(String).new

  # Use Hash for key-value mappings
  @cache = {} of String => String

  def call(request : HttpRequest, response : Response) : Response
    # Use String.build for string concatenation in loops
    result = String.build do |str|
      @small_list.each do |item|
        str << item
        str << "\n"
      end
    end

    Response.new(body: result)
  end
end
```

### Resource Management

```crystal
# Proper resource cleanup
class DatabaseHandler
  include Handler

  def call(request : HttpRequest, response : Response) : Response
    connection = database_pool.checkout

    begin
      result = process_with_connection(connection, request)
      Response.new(body: result)
    ensure
      database_pool.checkin(connection)
    end
  end
end
```

## Security Standards

### Input Validation

```crystal
# Comprehensive input validation
struct SecureRequest
  include Request

  # Sanitize and validate all inputs
  validates :username, presence: true, length: {min: 3, max: 20}, format: /^[a-zA-Z0-9_]+$/
  validates :email, presence: true, format: :email
  validates :password, presence: true, length: {min: 8}, format: /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/

  # Custom validation for security
  validate :no_sql_injection
  validate :no_xss_attempts

  private def no_sql_injection
    sql_patterns = ["SELECT", "INSERT", "UPDATE", "DELETE", "DROP", "CREATE"]

    sql_patterns.each do |pattern|
      if username?.try(&.upcase.includes?(pattern)) || email?.try(&.upcase.includes?(pattern))
        errors.add(:base, "Invalid input detected")
        break
      end
    end
  end

  private def no_xss_attempts
    xss_patterns = ["<script>", "javascript:", "onload=", "onerror="]

    xss_patterns.each do |pattern|
      if username?.try(&.downcase.includes?(pattern)) || email?.try(&.downcase.includes?(pattern))
        errors.add(:base, "Invalid input detected")
        break
      end
    end
  end
end
```

### Authentication and Authorization

```crystal
# Secure authentication handler
class SecureAuthHandler
  include Handler

  def initialize(@secret_key : String, @rate_limiter : RateLimiter)
  end

  def call(request : HttpRequest, response : Response) : Response
    # Rate limiting
    unless @rate_limiter.allow?(request.ip)
      return Response.new(status: 429, body: "Too many requests")
    end

    # Token validation with proper error handling
    token = extract_token(request)

    unless valid_token?(token)
      # Log failed attempt
      log_failed_attempt(request.ip)

      return Response.new(
        status: 401,
        body: {error: "Invalid credentials"}.to_json,
        headers: {"Content-Type" => "application/json"}
      )
    end

    @next.call(request, response)
  end

  private def valid_token?(token : String?) : Bool
    return false unless token

    # Use constant-time comparison to prevent timing attacks
    JWT.decode(token, @secret_key, JWT::Algorithm::HS256)
    true
  rescue JWT::Error
    false
  end
end
```

## Error Handling Standards

### Exception Handling

```crystal
# Comprehensive error handling
class RobustHandler
  include Handler

  def call(request : HttpRequest, response : Response) : Response
    @next.call(request, response)
  rescue ex : DatabaseError
    handle_database_error(ex, request, response)
  rescue ex : ValidationError
    handle_validation_error(ex, request, response)
  rescue ex : AuthenticationError
    handle_authentication_error(ex, request, response)
  rescue ex : Exception
    handle_generic_error(ex, request, response)
  end

  private def handle_database_error(ex : DatabaseError, request : HttpRequest, response : Response) : Response
    # Log the error
    Log.error { "Database error: #{ex.message}" }

    # Return appropriate response
    Response.new(
      status: 503,
      body: {error: "Service temporarily unavailable"}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end

  private def handle_validation_error(ex : ValidationError, request : HttpRequest, response : Response) : Response
    Response.new(
      status: 422,
      body: {errors: ex.errors}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end
end
```

### Logging Standards

```crystal
# Structured logging
class LoggingHandler
  include Handler

  def call(request : HttpRequest, response : Response) : Response
    start_time = Time.monotonic

    result = @next.call(request, response)

    duration = Time.monotonic - start_time

    # Structured logging
    Log.info {
      {
        method: request.method,
        path: request.path,
        status: result.status,
        duration: duration.total_milliseconds,
        ip: request.ip,
        user_agent: request.headers["User-Agent"]?
      }
    }

    result
  rescue ex : Exception
    # Error logging
    Log.error(exception: ex) {
      {
        method: request.method,
        path: request.path,
        error: ex.message,
        ip: request.ip
      }
    }

    raise ex
  end
end
```

## Code Review Standards

### Review Checklist

```markdown
## Code Review Checklist

### Functionality

- [ ] Does the code work as intended?
- [ ] Are all edge cases handled?
- [ ] Are error conditions properly managed?
- [ ] Does the code follow the established patterns?

### Code Quality

- [ ] Is the code readable and well-documented?
- [ ] Are there any code smells or anti-patterns?
- [ ] Is the code properly tested?
- [ ] Are there any performance concerns?

### Security

- [ ] Are inputs properly validated?
- [ ] Are there any security vulnerabilities?
- [ ] Is sensitive data properly handled?
- [ ] Are authentication/authorization checks in place?

### Testing

- [ ] Are unit tests comprehensive?
- [ ] Are integration tests included?
- [ ] Do tests cover edge cases?
- [ ] Are tests maintainable?

### Documentation

- [ ] Is the code properly documented?
- [ ] Are API changes documented?
- [ ] Are breaking changes noted?
- [ ] Is the README updated if needed?
```

### Review Process

```crystal
# Pull request template
# .github/pull_request_template.md

## Description
Brief description of the changes made.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No breaking changes (or breaking changes documented)

## Related Issues
Closes #(issue number)
```

## Best Practices

### 1. Keep It Simple

```crystal
# Good: Simple and readable
def calculate_total(items : Array(Item)) : Float64
  items.sum(&.price)
end

# Avoid: Overly complex
def calculate_total(items : Array(Item)) : Float64
  items.reduce(0.0) do |acc, item|
    acc + item.price
  end
end
```

### 2. Fail Fast

```crystal
# Good: Fail fast with clear error messages
def process_user(user : User) : Bool
  raise ArgumentError.new("User cannot be nil") if user.nil?
  raise ArgumentError.new("User must be valid") unless user.valid?

  # Process user
  user.save
end
```

### 3. Be Explicit

```crystal
# Good: Explicit type annotations
def create_user(name : String, email : String) : User
  User.new(name: name, email: email)
end

# Avoid: Implicit types
def create_user(name, email)
  User.new(name: name, email: email)
end
```

## Next Steps

- [Development Setup](setup.md) - Setting up your development environment
- [Roadmap](roadmap.md) - Development roadmap and priorities
- [Contributing Guidelines](contributing.md) - General contributing guidelines

---

_Following these standards ensures consistent, maintainable, and high-quality code for the Azu framework._

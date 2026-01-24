# How to Test Endpoints

This guide shows you how to write tests for your Azu endpoints.

## Basic Test Setup

Create a spec helper:

```crystal
# spec/spec_helper.cr
require "spec"
require "../src/app"

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

  def with_auth(headers : HTTP::Headers, token : String) : HTTP::Headers
    headers["Authorization"] = "Bearer #{token}"
    headers
  end

  def parse_json_response(context) : JSON::Any
    context.response.close
    body = context.response.@io.as(IO::Memory).to_s
    JSON.parse(body.split("\r\n\r\n").last)
  end
end
```

## Testing GET Endpoints

```crystal
# spec/endpoints/show_user_endpoint_spec.cr
require "../spec_helper"

describe ShowUserEndpoint do
  include TestHelpers

  before_each do
    User.delete_all
  end

  describe "#call" do
    it "returns user when found" do
      user = User.create!(name: "Alice", email: "alice@example.com")

      context = create_context("GET", "/users/#{user.id}")
      endpoint = ShowUserEndpoint.new
      endpoint.context = context
      endpoint.params = {"id" => user.id.to_s}

      response = endpoint.call

      response.should be_a(UserResponse)
      context.response.status_code.should eq(200)
    end

    it "returns 404 for non-existent user" do
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

## Testing POST Endpoints

```crystal
# spec/endpoints/create_user_endpoint_spec.cr
require "../spec_helper"

describe CreateUserEndpoint do
  include TestHelpers

  before_each do
    User.delete_all
  end

  describe "#call" do
    it "creates user with valid data" do
      body = {name: "Alice", email: "alice@example.com", age: 30}.to_json

      context = create_context("POST", "/users", body, json_headers)
      endpoint = CreateUserEndpoint.new
      endpoint.context = context

      response = endpoint.call

      response.should be_a(UserResponse)
      context.response.status_code.should eq(201)

      User.count.should eq(1)
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
      body = {name: "Alice", email: "invalid"}.to_json

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

## Testing PUT/PATCH Endpoints

```crystal
describe UpdateUserEndpoint do
  include TestHelpers

  it "updates user attributes" do
    user = User.create!(name: "Alice", email: "alice@example.com")
    body = {name: "Alice Smith"}.to_json

    context = create_context("PUT", "/users/#{user.id}", body, json_headers)
    endpoint = UpdateUserEndpoint.new
    endpoint.context = context
    endpoint.params = {"id" => user.id.to_s}

    response = endpoint.call

    response.should be_a(UserResponse)
    User.find(user.id).name.should eq("Alice Smith")
  end
end
```

## Testing DELETE Endpoints

```crystal
describe DeleteUserEndpoint do
  include TestHelpers

  it "deletes the user" do
    user = User.create!(name: "Alice", email: "alice@example.com")

    context = create_context("DELETE", "/users/#{user.id}")
    endpoint = DeleteUserEndpoint.new
    endpoint.context = context
    endpoint.params = {"id" => user.id.to_s}

    endpoint.call

    context.response.status_code.should eq(204)
    User.find?(user.id).should be_nil
  end
end
```

## Testing with Authentication

```crystal
describe ProtectedEndpoint do
  include TestHelpers

  it "returns 401 without token" do
    context = create_context("GET", "/protected")
    endpoint = ProtectedEndpoint.new
    endpoint.context = context

    expect_raises(Azu::Response::Unauthorized) do
      endpoint.call
    end
  end

  it "succeeds with valid token" do
    user = User.create!(name: "Alice", email: "alice@example.com")
    token = Token.create(user_id: user.id)

    headers = with_auth(json_headers, token)
    context = create_context("GET", "/protected", nil, headers)
    endpoint = ProtectedEndpoint.new
    endpoint.context = context

    response = endpoint.call
    context.response.status_code.should eq(200)
  end
end
```

## Integration Tests

Test the full request/response cycle:

```crystal
# spec/integration/users_api_spec.cr
require "../spec_helper"
require "http/client"

describe "Users API" do
  BASE_URL = "http://localhost:4000"

  before_all do
    # Start server in background
    spawn { MyApp.start }
    sleep 1.second
  end

  describe "POST /users" do
    it "creates a new user" do
      response = HTTP::Client.post(
        "#{BASE_URL}/users",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: {name: "Test User", email: "test@example.com"}.to_json
      )

      response.status_code.should eq(201)

      data = JSON.parse(response.body)
      data["name"].should eq("Test User")
      data["email"].should eq("test@example.com")
    end
  end

  describe "GET /users/:id" do
    it "returns the user" do
      # Create user first
      create_response = HTTP::Client.post(
        "#{BASE_URL}/users",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: {name: "Test", email: "test@example.com"}.to_json
      )
      user_id = JSON.parse(create_response.body)["id"]

      # Get user
      response = HTTP::Client.get("#{BASE_URL}/users/#{user_id}")

      response.status_code.should eq(200)
      JSON.parse(response.body)["id"].should eq(user_id)
    end
  end
end
```

## Testing Response Format

```crystal
it "returns correct JSON structure" do
  user = User.create!(name: "Alice", email: "alice@example.com")
  context = create_context("GET", "/users/#{user.id}")
  endpoint = ShowUserEndpoint.new
  endpoint.context = context
  endpoint.params = {"id" => user.id.to_s}

  endpoint.call

  json = parse_json_response(context)

  json["id"].should eq(user.id)
  json["name"].should eq("Alice")
  json["email"].should eq("alice@example.com")
  json.as_h.has_key?("password").should be_false
end
```

## Running Tests

```bash
# Run all tests
crystal spec

# Run specific file
crystal spec spec/endpoints/create_user_endpoint_spec.cr

# Run with verbose output
crystal spec --verbose

# Run tagged tests
crystal spec --tag focus
```

## See Also

- [Test WebSockets](test-websockets.md)

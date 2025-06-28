# Core Modules API Reference

This document provides a comprehensive reference for Azu's core modules, including endpoints, requests, responses, and routing.

## Endpoint Module

### `Azu::Endpoint`

The core endpoint module that provides type-safe HTTP request handling.

```crystal
module Azu::Endpoint
  # Include this module to create type-safe endpoints
  include Endpoint(RequestType, ResponseType)
end
```

#### Methods

##### `get(path : String, **options)`

Registers a GET route for the endpoint.

```crystal
struct UserEndpoint
  include Endpoint(UserRequest, UserResponse)

  get "/users/:id"
  get "/users", constraints: {id: /\d+/}
  get "/users", middleware: [AuthMiddleware]
end
```

**Parameters:**

- `path` - The route path pattern
- `constraints` - Route parameter constraints (optional)
- `middleware` - Route-specific middleware (optional)
- `only` - HTTP methods to allow (optional)

##### `post(path : String, **options)`

Registers a POST route for the endpoint.

```crystal
post "/users"
post "/users", middleware: [ValidationMiddleware]
```

##### `put(path : String, **options)`

Registers a PUT route for the endpoint.

```crystal
put "/users/:id"
```

##### `patch(path : String, **options)`

Registers a PATCH route for the endpoint.

```crystal
patch "/users/:id"
```

##### `delete(path : String, **options)`

Registers a DELETE route for the endpoint.

```crystal
delete "/users/:id"
```

##### `head(path : String, **options)`

Registers a HEAD route for the endpoint.

```crystal
head "/users"
```

##### `options(path : String, **options)`

Registers an OPTIONS route for the endpoint.

```crystal
options "/users"
```

##### `call : ResponseType`

The main endpoint method that must be implemented.

```crystal
def call : UserResponse
  # Implementation here
  UserResponse.new(user: find_user(request.id))
end
```

## Request Module

### `Azu::Request`

Base module for type-safe request objects.

```crystal
module Azu::Request
  # Include this module to create request contracts
end
```

#### Methods

##### `self.from_params(params : Params) : self`

Factory method to create request objects from parameters.

```crystal
def self.from_params(params : Params) : self
  new(
    id: params.get_int("id"),
    name: params.get_string("name"),
    email: params.get_string("email")
  )
end
```

##### `self.schema : Schema`

Define validation schema for the request.

```crystal
def self.schema : Schema
  Schema.new(
    id: Int32,
    name: String,
    email: String
  )
end
```

## Response Module

### `Azu::Response`

Base module for type-safe response objects.

```crystal
module Azu::Response
  # Include this module to create response objects
end
```

#### Methods

##### `render : String`

Convert the response object to a string representation.

```crystal
def render : String
  {
    "id" => user.id,
    "name" => user.name,
    "email" => user.email
  }.to_json
end
```

##### `headers : HTTP::Headers`

Return custom HTTP headers for the response.

```crystal
def headers : HTTP::Headers
  headers = HTTP::Headers.new
  headers["Content-Type"] = "application/json"
  headers["Cache-Control"] = "no-cache"
  headers
end
```

##### `status : Int32`

Return the HTTP status code for the response.

```crystal
def status : Int32
  200
end
```

## Params Module

### `Azu::Params`

Type-safe parameter extraction from HTTP requests.

```crystal
class Azu::Params
  # Provides type-safe access to request parameters
end
```

#### Methods

##### `get_string(key : String) : String`

Extract a string parameter.

```crystal
name = params.get_string("name")
```

##### `get_string?(key : String) : String?`

Extract an optional string parameter.

```crystal
description = params.get_string?("description")
```

##### `get_int(key : String) : Int32`

Extract an integer parameter.

```crystal
id = params.get_int("id")
```

##### `get_int?(key : String) : Int32?`

Extract an optional integer parameter.

```crystal
age = params.get_int?("age")
```

##### `get_float(key : String) : Float64`

Extract a float parameter.

```crystal
price = params.get_float("price")
```

##### `get_float?(key : String) : Float64?`

Extract an optional float parameter.

```crystal
rating = params.get_float?("rating")
```

##### `get_bool(key : String) : Bool`

Extract a boolean parameter.

```crystal
active = params.get_bool("active")
```

##### `get_bool?(key : String) : Bool?`

Extract an optional boolean parameter.

```crystal
featured = params.get_bool?("featured")
```

##### `get_file(key : String) : Azu::FileUpload`

Extract a file upload.

```crystal
file = params.get_file("upload")
```

##### `get_files(key : String) : Array(Azu::FileUpload)`

Extract multiple file uploads.

```crystal
files = params.get_files("uploads")
```

##### `get_array(key : String) : Array(String)`

Extract an array parameter.

```crystal
tags = params.get_array("tags")
```

##### `get_hash(key : String) : Hash(String, String)`

Extract a hash parameter.

```crystal
metadata = params.get_hash("metadata")
```

##### `to_h : Hash(String, String)`

Convert all parameters to a hash.

```crystal
all_params = params.to_h
```

## Router Module

### `Azu::Router`

High-performance routing using Radix trees.

```crystal
class Azu::Router
  # Handles route matching and parameter extraction
end
```

#### Methods

##### `add(method : String, path : String, handler : Handler)`

Add a route to the router.

```crystal
router.add("GET", "/users/:id", user_handler)
```

##### `find(method : String, path : String) : RouteMatch?`

Find a matching route for the given method and path.

```crystal
if match = router.find("GET", "/users/123")
  params = match.params
  handler = match.handler
end
```

##### `routes : Array(Route)`

Get all registered routes.

```crystal
all_routes = router.routes
```

## Channel Module

### `Azu::Channel`

WebSocket channel handling for real-time features.

```crystal
class Azu::Channel < Azu::Base
  # Base class for WebSocket channels
end
```

#### Methods

##### `ws(path : String)`

Register a WebSocket route.

```crystal
class ChatChannel < Azu::Channel
  ws "/ws/chat/:room_id"
end
```

##### `on_connect`

Called when a client connects to the channel.

```crystal
def on_connect
  Log.info { "Client connected to chat room" }
end
```

##### `on_message(message : String)`

Called when a message is received from a client.

```crystal
def on_message(message : String)
  broadcast(message)
end
```

##### `on_disconnect`

Called when a client disconnects from the channel.

```crystal
def on_disconnect
  Log.info { "Client disconnected from chat room" }
end
```

##### `broadcast(message : String)`

Send a message to all connected clients.

```crystal
def broadcast(message : String)
  # Implementation
end
```

##### `send_to(client_id : String, message : String)`

Send a message to a specific client.

```crystal
def send_to(client_id : String, message : String)
  # Implementation
end
```

## Component Module

### `Azu::Component`

Live components for real-time UI updates.

```crystal
class Azu::Component
  # Base class for live components
end
```

#### Methods

##### `content`

Generate the component's HTML content.

```crystal
def content
  div class: "user-card" do
    h3 user.name
    p user.email
  end
end
```

##### `on_event(event : String, data : Hash(String, JSON::Any))`

Handle client-side events.

```crystal
def on_event(event : String, data : Hash(String, JSON::Any))
  case event
  when "click"
    handle_click(data)
  when "update"
    handle_update(data)
  end
end
```

##### `update_content`

Update the component's content and notify clients.

```crystal
def update_content
  # Update internal state
  @show_details = !@show_details

  # Notify clients of the change
  broadcast_update
end
```

## Templates Module

### `Azu::Templates`

Template rendering and hot reloading support.

```crystal
module Azu::Templates
  # Template engine integration
end
```

#### Methods

##### `render(template : String, data : Hash) : String`

Render a template with data.

```crystal
html = Templates.render("user.html", {"user" => user})
```

##### `renderable`

Include this module to make a response renderable.

```crystal
struct UserPage
  include Response
  include Templates::Renderable

  def render
    view "user.html", {"user" => user}
  end
end
```

## Configuration Module

### `Azu::Configuration`

Application configuration management.

```crystal
class Azu::Configuration
  # Centralized configuration management
end
```

#### Properties

##### `host : String`

The host to bind the server to.

```crystal
Configuration.host = "0.0.0.0"
```

##### `port : Int32`

The port to bind the server to.

```crystal
Configuration.port = 3000
```

##### `workers : Int32`

The number of worker processes.

```crystal
Configuration.workers = 4
```

##### `ssl_enabled : Bool`

Whether SSL/TLS is enabled.

```crystal
Configuration.ssl_enabled = true
```

##### `ssl_cert_path : String?`

Path to the SSL certificate file.

```crystal
Configuration.ssl_cert_path = "/path/to/cert.pem"
```

##### `ssl_key_path : String?`

Path to the SSL private key file.

```crystal
Configuration.ssl_key_path = "/path/to/key.pem"
```

## Error Module

### `Azu::Error`

Error handling and custom exceptions.

```crystal
class Azu::Error < Exception
  # Base error class for Azu applications
end
```

#### Subclasses

##### `Azu::Error::NotFound`

Raised when a resource is not found.

```crystal
raise Azu::Error::NotFound.new("User not found")
```

##### `Azu::Error::BadRequest`

Raised when the request is malformed.

```crystal
raise Azu::Error::BadRequest.new("Invalid parameters")
```

##### `Azu::Error::Unauthorized`

Raised when authentication is required.

```crystal
raise Azu::Error::Unauthorized.new("Authentication required")
```

##### `Azu::Error::Forbidden`

Raised when access is denied.

```crystal
raise Azu::Error::Forbidden.new("Access denied")
```

##### `Azu::Error::InternalServerError`

Raised when an internal error occurs.

```crystal
raise Azu::Error::InternalServerError.new("Database connection failed")
```

## Logging Module

### `Azu::Log`

Structured logging for Azu applications.

```crystal
module Azu::Log
  # Logging utilities and configuration
end
```

#### Methods

##### `info(message : String)`

Log an info message.

```crystal
Log.info { "User #{user.id} logged in" }
```

##### `debug(message : String)`

Log a debug message.

```crystal
Log.debug { "Processing request: #{request.path}" }
```

##### `warn(message : String)`

Log a warning message.

```crystal
Log.warn { "Rate limit exceeded for IP: #{ip}" }
```

##### `error(message : String)`

Log an error message.

```crystal
Log.error { "Database connection failed: #{ex.message}" }
```

##### `fatal(message : String)`

Log a fatal message.

```crystal
Log.fatal { "Application startup failed: #{ex.message}" }
```

## Utility Modules

### `Azu::Utils`

Common utility functions and helpers.

```crystal
module Azu::Utils
  # Utility functions for common tasks
end
```

#### Methods

##### `generate_id : String`

Generate a unique identifier.

```crystal
id = Utils.generate_id
```

##### `slugify(text : String) : String`

Convert text to a URL-friendly slug.

```crystal
slug = Utils.slugify("Hello World!") # => "hello-world"
```

##### `encrypt(data : String, key : String) : String`

Encrypt sensitive data.

```crystal
encrypted = Utils.encrypt("sensitive data", secret_key)
```

##### `decrypt(data : String, key : String) : String`

Decrypt encrypted data.

```crystal
decrypted = Utils.decrypt(encrypted_data, secret_key)
```

##### `hash_password(password : String) : String`

Hash a password for storage.

```crystal
hashed = Utils.hash_password("user_password")
```

##### `verify_password(password : String, hash : String) : Bool`

Verify a password against its hash.

```crystal
valid = Utils.verify_password("user_password", stored_hash)
```

## Constants

### HTTP Methods

```crystal
GET     = "GET"
POST    = "POST"
PUT     = "PUT"
PATCH   = "PATCH"
DELETE  = "DELETE"
HEAD    = "HEAD"
OPTIONS = "OPTIONS"
```

### HTTP Status Codes

```crystal
OK                  = 200
CREATED             = 201
NO_CONTENT          = 204
BAD_REQUEST         = 400
UNAUTHORIZED        = 401
FORBIDDEN           = 403
NOT_FOUND           = 404
METHOD_NOT_ALLOWED  = 405
CONFLICT            = 409
UNPROCESSABLE_ENTITY = 422
INTERNAL_SERVER_ERROR = 500
```

### Content Types

```crystal
JSON = "application/json"
XML  = "application/xml"
HTML = "text/html"
TEXT = "text/plain"
```

## Type Definitions

### `Azu::FileUpload`

Represents an uploaded file.

```crystal
struct Azu::FileUpload
  getter filename : String
  getter content_type : String
  getter content : IO
  getter size : Int64
end
```

### `Azu::RouteMatch`

Represents a matched route.

```crystal
struct Azu::RouteMatch
  getter params : Hash(String, String)
  getter handler : Handler
  getter route : Route
end
```

### `Azu::Route`

Represents a registered route.

```crystal
struct Azu::Route
  getter method : String
  getter path : String
  getter handler : Handler
  getter constraints : Hash(String, Regex)?
  getter middleware : Array(Middleware)?
end
```

## Next Steps

- [Handler Classes](api-reference/handlers.md) - Built-in middleware handlers
- [Configuration Options](api-reference/configuration.md) - Configuration reference
- [Core Concepts](core-concepts.md) - Understanding the core concepts
- [Advanced Usage](advanced.md) - Advanced usage patterns

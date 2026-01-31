# FAQ & Troubleshooting

Common questions, issues, and solutions when working with Azu.

## Frequently Asked Questions

### General Questions

**Q: What makes Azu different from other web frameworks?**

A: Azu emphasizes compile-time type safety and contract-first development. Unlike traditional frameworks that validate at runtime, Azu catches errors during compilation, resulting in more reliable applications with zero runtime overhead for type checking.

**Q: Can I use Azu for production applications?**

A: Yes! Azu is built for production use with performance optimizations, comprehensive error handling, and scalability features. Many applications are successfully running Azu in production environments.

**Q: How does Azu compare to other Crystal web frameworks?**

A: Azu focuses on type-safe contracts and real-time features, while frameworks like Kemal prioritize simplicity. Azu provides more structure and compile-time guarantees at the cost of some flexibility.

**Q: Do I need to learn Crystal to use Azu?**

A: Yes, basic Crystal knowledge is required. However, Crystal's syntax is similar to Ruby, making it approachable for developers from many backgrounds.

### Technical Questions

**Q: How do I handle database connections in Azu?**

A: Azu recommends CQL (Crystal Query Language) as the primary ORM. CQL provides type-safe database operations with compile-time validation:

```crystal
require "cql"
require "azu"

# Define schema
AppDB = CQL::Schema.define(:app, adapter: CQL::Adapter::Postgres, uri: ENV["DATABASE_URL"]) do
  table :users do
    primary :id, Int64
    text :name
    text :email
    timestamps
  end
end

# Define model
struct User
  include CQL::ActiveRecord::Model(Int64)
  db_context AppDB, :users

  getter id : Int64?
  getter name : String
  getter email : String
end

# Use in endpoint
struct UserEndpoint
  include Azu::Endpoint(EmptyRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user = User.find(params["id"].to_i64)
    UserResponse.new(user)
  end
end
```

See the [Database documentation](reference/database/cql-api.md) for complete CQL integration details.

**Q: Can I use Azu with existing Crystal libraries?**

A: Absolutely! Azu is designed to work with the Crystal ecosystem. You can use any Crystal shard or library within your Azu applications.

**Q: How do I handle authentication?**

A: Implement authentication using middleware:

```crystal
class AuthenticationHandler
  include HTTP::Handler

  def call(context)
    token = context.request.headers["Authorization"]?

    unless token && valid_token?(token)
      context.response.status = HTTP::Status::UNAUTHORIZED
      context.response.print "Authentication required"
      return
    end

    context.set("current_user", get_user_from_token(token))
    call_next(context)
  end
end

# Add to middleware stack
MyApp.start [
  AuthenticationHandler.new,
  # ... other handlers
]
```

**Q: How do I deploy Azu applications?**

A: Compile your application and deploy the binary:

```bash
# Build for production
crystal build --release --no-debug src/my_app.cr

# Deploy binary to server
scp my_app user@server:/opt/myapp/
```

## Common Issues

### Compilation Issues

**Problem: "can't infer type" errors**

```crystal
# ❌ This causes type inference issues
def create_user(request)
  # Crystal can't infer the request type
end

# ✅ Use explicit types
def create_user(request : CreateUserRequest) : UserResponse
  # Clear type information
end
```

**Problem: Template compilation errors**

```
Error: can't find template "users/show.html"
```

**Solution:** Check template paths in configuration:

```crystal
configure do
  templates.path = ["templates", "views"] # Add all template directories
  template_hot_reload = env.development?  # Enable hot reload for development
end
```

### Runtime Issues

**Problem: WebSocket connections not working**

**Symptoms:**

- WebSocket connection fails
- No error messages in logs
- Client can't connect

**Solutions:**

1. Check WebSocket route registration:

```crystal
class MyChannel < Azu::Channel
  ws "/websocket" # Make sure this matches client URL

  def on_connect
    # Implementation
  end
end
```

2. Verify middleware order:

```crystal
MyApp.start [
  Azu::Handler::Logger.new,
  # Don't put static handler before WebSocket routes
  # WebSocket handlers should come early in the stack
]
```

3. Check client-side connection:

```javascript
// Make sure URL matches server route
const ws = new WebSocket("ws://localhost:4000/websocket");
```

**Problem: Request validation not working**

**Symptoms:**

- Validation rules ignored
- Invalid data passes through

**Solutions:**

1. Ensure validation is called:

```crystal
def call : UserResponse
  # Always validate before processing
  unless create_user_request.valid?
    raise Azu::Response::ValidationError.new(
      create_user_request.errors.group_by(&.field).transform_values(&.map(&.message))
    )
  end

  # Process validated request
  UserResponse.new(create_user(create_user_request))
end
```

2. Check validation rules syntax:

```crystal
struct UserRequest
  include Azu::Request

  getter name : String
  getter email : String

  # ✅ Correct validation syntax
  validate name, presence: true, length: {min: 2}
  validate email, presence: true, format: /@/

  def initialize(@name = "", @email = "")
  end
end
```

**Problem: File uploads not working**

**Symptoms:**

- File uploads fail silently
- Uploaded files are empty
- Memory issues with large files

**Solutions:**

1. Configure upload limits:

```crystal
configure do
  upload.max_file_size = 50.megabytes
  upload.temp_dir = "/tmp/uploads"
end
```

2. Handle multipart data correctly:

```crystal
struct FileUploadRequest
  include Azu::Request

  getter file : Azu::Params::Multipart::File?
  getter description : String

  def initialize(@file = nil, @description = "")
  end
end

def call : FileUploadResponse
  if file = file_upload_request.file
    # Validate file
    raise error("File too large") if file.size > 10.megabytes

    # Save file
    final_path = save_uploaded_file(file)
    file.cleanup # Important: clean up temp file

    FileUploadResponse.new(path: final_path)
  else
    raise error("File is required")
  end
end
```

### Performance Issues

**Problem: Slow response times**

**Diagnosis:**

1. Enable request logging:

```crystal
MyApp.start [
  Azu::Handler::Logger.new, # Add this first
  # ... other handlers
]
```

2. Check for blocking operations:

```crystal
def call : UserResponse
  # ❌ Blocking database call
  users = database.query("SELECT * FROM users") # Blocks fiber

  # ✅ Use async operations when possible
  users = database.async_query("SELECT * FROM users")
  UserResponse.new(users)
end
```

**Problem: Memory leaks**

**Common causes:**

- Not cleaning up file uploads
- Keeping references to WebSocket connections
- Large object creation in loops

**Solutions:**

1. Clean up resources:

```crystal
def handle_file_upload(file)
  process_file(file)
ensure
  file.cleanup if file # Always cleanup
end
```

2. Manage WebSocket connections:

```crystal
class MyChannel < Azu::Channel
  CONNECTIONS = Set(HTTP::WebSocket).new

  def on_connect
    CONNECTIONS << socket.not_nil!
  end

  def on_close(code, message)
    CONNECTIONS.delete(socket) # Remove on disconnect
  end
end
```

### Development Issues

**Problem: Hot reload not working**

**Solutions:**

1. Enable in configuration:

```crystal
configure do
  template_hot_reload = env.development? # Make sure this is true
end
```

2. Check file permissions and paths:

```bash
# Make sure template files are readable
chmod -R 644 templates/
```

**Problem: CORS issues in development**

**Symptoms:**

- Browser blocks requests from frontend
- CORS errors in console

**Solution:**

```crystal
MyApp.start [
  Azu::Handler::CORS.new(
    allowed_origins: ["http://localhost:3000"], # Add your frontend URL
    allowed_methods: %w(GET POST PUT PATCH DELETE OPTIONS),
    allowed_headers: %w(Accept Content-Type Authorization)
  ),
  # ... other handlers
]
```

## Debugging Tips

### Enable Debug Logging

```crystal
configure do
  log.level = Log::Severity::DEBUG # See all log messages
end
```

### Inspect Request Data

```crystal
def call : UserResponse
  Log.debug { "Request data: #{create_user_request.inspect}" }
  Log.debug { "Params: #{params.to_hash}" }
  Log.debug { "Headers: #{context.request.headers}" }

  # ... endpoint logic
end
```

### Use Crystal's Built-in Debugging

```crystal
# Add pp for pretty printing
require "pp"

def call : UserResponse
  pp create_user_request # Pretty print request object
  pp params.to_hash      # Pretty print parameters

  # ... endpoint logic
end
```

### Test Individual Components

```crystal
# Test request contracts in isolation
user_request = CreateUserRequest.new(name: "test", email: "test@example.com")
puts user_request.valid?
puts user_request.errors.map(&.message)

# Test response objects
user = User.new(name: "test")
response = UserResponse.new(user)
puts response.render
```

## Performance Troubleshooting

### Profile Your Application

```crystal
require "benchmark"

def call : UserResponse
  time = Benchmark.measure do
    # Your endpoint logic here
  end

  Log.info { "Endpoint took #{time.total_seconds}s" }

  # ... return response
end
```

### Monitor Memory Usage

```bash
# Check memory usage during runtime
ps aux | grep my_app

# Use Crystal's built-in memory tracking
crystal run --stats src/my_app.cr
```

### Database Query Optimization

```crystal
# Log slow queries
def call : UserResponse
  start_time = Time.instant

  users = database.query("SELECT * FROM users WHERE active = true")

  duration = Time.instant - start_time
  if duration > 100.milliseconds
    Log.warn { "Slow query detected: #{duration.total_milliseconds}ms" }
  end

  UserResponse.new(users)
end
```

## Getting Help

### Community Resources

- **GitHub Issues**: [azutoolkit/azu/issues](https://github.com/azutoolkit/azu/issues)
- **Crystal Community**: [Crystal Language Forum](https://forum.crystal-lang.org/)
- **Documentation**: [Official Azu Docs](https://azutopia.gitbook.io/azu/)

### Reporting Issues

When reporting issues, include:

1. **Crystal version**: `crystal version`
2. **Azu version**: Check `shard.yml`
3. **Minimal reproduction case**
4. **Error messages and stack traces**
5. **Environment details** (OS, deployment method)

### Example Issue Report

````
**Crystal Version**: 1.10.1
**Azu Version**: 0.5.26
**OS**: macOS 13.0

**Issue**: WebSocket connection fails with "Connection refused"

**Reproduction**:
```crystal
class TestChannel < Azu::Channel
  ws "/test"
  def on_connect
    puts "Connected"
  end
end
````

**Error**: Connection refused when trying to connect to ws://localhost:4000/test

**Expected**: WebSocket connection should succeed

```

---

**Still need help?** Check the [Contributing Guide](contributing/setup.md) for information on getting support from the community.
```

# Async Logging

Asynchronous logging in Azu provides high-performance, non-blocking log processing that ensures your application remains responsive even under heavy logging loads. With support for multiple log levels, structured logging, and external log aggregation, async logging is essential for production applications.

## What is Async Logging?

Async logging in Azu provides:

- **Non-blocking**: Log operations don't block the main thread
- **High Performance**: Efficient log processing with minimal overhead
- **Structured Logging**: JSON-formatted logs with metadata
- **Multiple Outputs**: Console, file, and external log aggregation
- **Log Levels**: Configurable log levels for different environments

## Basic Async Logging

### Configuration

```crystal
module MyApp
  include Azu

  configure do |config|
    # Enable async logging
    config.logging.async = true
    config.logging.async_buffer_size = 1000
    config.logging.async_flush_interval = 1.second

    # Configure log levels
    config.logging.level = config.env.development? ? Log::Severity::DEBUG : Log::Severity::INFO

    # Configure outputs
    config.logging.outputs = [:console, :file, :external]
    config.logging.file_path = "logs/app.log"
    config.logging.external_endpoint = "https://logs.example.com/api/logs"
  end
end
```

### Basic Usage

```crystal
class UserService
  def create_user(user_data : Hash(String, JSON::Any)) : User
    # Log user creation
    Log.info { "Creating user: #{user_data["email"]}" }

    begin
      user = User.new(user_data)
      user.save

      # Log success
      Log.info { "User created successfully: #{user.id}" }
      user
    rescue e
      # Log error
      Log.error(exception: e) { "Failed to create user: #{e.message}" }
      raise
    end
  end
end
```

## Structured Logging

### JSON Logging

```crystal
class StructuredLogger
  def self.log_user_action(action : String, user_id : Int64, metadata : Hash(String, JSON::Any))
    log_data = {
      timestamp: Time.utc.to_rfc3339,
      level: "info",
      message: "User action: #{action}",
      user_id: user_id,
      metadata: metadata
    }

    Log.info { log_data.to_json }
  end

  def self.log_request(request_id : String, method : String, path : String, duration : Time::Span)
    log_data = {
      timestamp: Time.utc.to_rfc3339,
      level: "info",
      message: "HTTP request",
      request_id: request_id,
      method: method,
      path: path,
      duration_ms: duration.total_milliseconds
    }

    Log.info { log_data.to_json }
  end

  def self.log_error(error : Exception, context : Hash(String, JSON::Any))
    log_data = {
      timestamp: Time.utc.to_rfc3339,
      level: "error",
      message: error.message,
      exception: error.class.name,
      backtrace: error.backtrace,
      context: context
    }

    Log.error { log_data.to_json }
  end
end
```

### Contextual Logging

```crystal
class ContextualLogger
  def initialize(@context : Hash(String, JSON::Any))
  end

  def info(message : String, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
    log_data = {
      timestamp: Time.utc.to_rfc3339,
      level: "info",
      message: message,
      context: @context,
      metadata: metadata
    }

    Log.info { log_data.to_json }
  end

  def error(message : String, exception : Exception? = nil, metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
    log_data = {
      timestamp: Time.utc.to_rfc3339,
      level: "error",
      message: message,
      context: @context,
      metadata: metadata
    }

    if exception
      log_data["exception"] = exception.class.name
      log_data["backtrace"] = exception.backtrace
    end

    Log.error { log_data.to_json }
  end
end
```

## Log Levels

### Configurable Log Levels

```crystal
class LogLevelManager
  def self.configure_log_levels
    # Development: Debug level
    if Azu.env.development?
      Log.setup(:debug)
    end

    # Production: Info level
    if Azu.env.production?
      Log.setup(:info)
    end

    # Test: Error level
    if Azu.env.test?
      Log.setup(:error)
    end
  end

  def self.set_log_level(level : Log::Severity)
    Log.setup(level)
  end

  def self.set_component_log_level(component : String, level : Log::Severity)
    Log.setup(component, level)
  end
end
```

### Conditional Logging

```crystal
class ConditionalLogger
  def self.debug_if_enabled(message : String, &block)
    if Log.level <= Log::Severity::DEBUG
      Log.debug { message }
      yield if block
    end
  end

  def self.info_if_enabled(message : String, &block)
    if Log.level <= Log::Severity::INFO
      Log.info { message }
      yield if block
    end
  end

  def self.warn_if_enabled(message : String, &block)
    if Log.level <= Log::Severity::WARN
      Log.warn { message }
      yield if block
    end
  end
end
```

## Log Outputs

### Console Logging

```crystal
class ConsoleLogger
  def self.setup_console_logging
    Log.setup do |c|
      c.bind "*", :info, Log::IOBackend.new(STDOUT)
      c.bind "*", :warn, Log::IOBackend.new(STDERR)
      c.bind "*", :error, Log::IOBackend.new(STDERR)
    end
  end

  def self.setup_colored_console_logging
    Log.setup do |c|
      c.bind "*", :info, Log::IOBackend.new(STDOUT, formatter: ColoredFormatter.new)
      c.bind "*", :warn, Log::IOBackend.new(STDERR, formatter: ColoredFormatter.new)
      c.bind "*", :error, Log::IOBackend.new(STDERR, formatter: ColoredFormatter.new)
    end
  end
end
```

### File Logging

```crystal
class FileLogger
  def self.setup_file_logging(log_file : String)
    Log.setup do |c|
      c.bind "*", :info, Log::IOBackend.new(File.open(log_file, "a"))
      c.bind "*", :warn, Log::IOBackend.new(File.open(log_file, "a"))
      c.bind "*", :error, Log::IOBackend.new(File.open(log_file, "a"))
    end
  end

  def self.setup_rotating_file_logging(log_file : String, max_size : Int64 = 10.megabytes)
    # Implement log rotation
    if File.exists?(log_file) && File.size(log_file) > max_size
      rotate_log_file(log_file)
    end

    setup_file_logging(log_file)
  end

  private def self.rotate_log_file(log_file : String)
    timestamp = Time.utc.to_s("%Y%m%d_%H%M%S")
    rotated_file = "#{log_file}.#{timestamp}"

    File.rename(log_file, rotated_file)

    # Compress old log files
    spawn compress_log_file(rotated_file)
  end

  private def self.compress_log_file(log_file : String)
    # Implement log compression
    # This would use gzip or similar
  end
end
```

### External Log Aggregation

```crystal
class ExternalLogger
  def self.setup_external_logging(endpoint : String, api_key : String)
    Log.setup do |c|
      c.bind "*", :info, ExternalLogBackend.new(endpoint, api_key)
      c.bind "*", :warn, ExternalLogBackend.new(endpoint, api_key)
      c.bind "*", :error, ExternalLogBackend.new(endpoint, api_key)
    end
  end
end

class ExternalLogBackend < Log::Backend
  def initialize(@endpoint : String, @api_key : String)
    @http_client = HTTP::Client.new(@endpoint)
    @http_client.basic_auth("Bearer", @api_key)
  end

  def write(entry : Log::Entry)
    log_data = {
      timestamp: entry.timestamp.to_rfc3339,
      level: entry.severity.to_s,
      message: entry.message,
      source: entry.source
    }

    # Send to external service
    spawn send_log(log_data)
  end

  private def send_log(log_data : Hash(String, JSON::Any))
    begin
      @http_client.post("/api/logs", headers: {"Content-Type" => "application/json"}) do |request|
        request.body = log_data.to_json
      end
    rescue e
      # Fallback to console if external service fails
      Log.error { "Failed to send log to external service: #{e.message}" }
    end
  end
end
```

## Performance Optimization

### Async Log Processing

```crystal
class AsyncLogProcessor
  def initialize(@buffer_size : Int32 = 1000, @flush_interval : Time::Span = 1.second)
    @log_queue = Channel(LogEntry).new(@buffer_size)
    @flush_timer = Timer.new(@flush_interval) { flush_logs }

    # Start log processing thread
    spawn process_logs
  end

  def log(entry : LogEntry)
    @log_queue.send(entry)
  end

  private def process_logs
    loop do
      entry = @log_queue.receive
      process_log_entry(entry)
    end
  end

  private def process_log_entry(entry : LogEntry)
    # Process log entry
    case entry.level
    when :info
      process_info_log(entry)
    when :warn
      process_warn_log(entry)
    when :error
      process_error_log(entry)
    end
  end

  private def flush_logs
    # Flush buffered logs
    # Implementation depends on log backend
  end
end
```

### Log Batching

```crystal
class LogBatcher
  def initialize(@batch_size : Int32 = 100, @batch_timeout : Time::Span = 5.seconds)
    @log_batch = [] of LogEntry
    @batch_mutex = Mutex.new
    @flush_timer = Timer.new(@batch_timeout) { flush_batch }
  end

  def add_log(entry : LogEntry)
    @batch_mutex.synchronize do
      @log_batch << entry

      if @log_batch.size >= @batch_size
        flush_batch
      end
    end
  end

  private def flush_batch
    @batch_mutex.synchronize do
      return if @log_batch.empty?

      # Send batch to external service
      send_log_batch(@log_batch.dup)
      @log_batch.clear
    end
  end

  private def send_log_batch(batch : Array(LogEntry))
    # Send batch to external service
    # This would use HTTP client to send multiple logs at once
  end
end
```

## Log Filtering

### Level-based Filtering

```crystal
class LogFilter
  def self.filter_by_level(level : Log::Severity) : Bool
    case level
    when Log::Severity::DEBUG
      Azu.env.development?
    when Log::Severity::INFO
      true
    when Log::Severity::WARN
      true
    when Log::Severity::ERROR
      true
    else
      false
    end
  end
end
```

### Component-based Filtering

```crystal
class ComponentLogFilter
  def self.filter_by_component(component : String) : Bool
    # Allow all components in development
    return true if Azu.env.development?

    # Filter components in production
    allowed_components = ["UserService", "AuthService", "PaymentService"]
    allowed_components.includes?(component)
  end
end
```

### Content-based Filtering

```crystal
class ContentLogFilter
  def self.filter_by_content(message : String) : Bool
    # Filter out sensitive information
    sensitive_patterns = [
      /password/i,
      /token/i,
      /secret/i,
      /key/i
    ]

    sensitive_patterns.none? { |pattern| message.match(pattern) }
  end
end
```

## Log Analysis

### Log Parsing

```crystal
class LogParser
  def self.parse_log_line(line : String) : LogEntry?
    begin
      log_data = JSON.parse(line).as_h

      LogEntry.new(
        timestamp: Time.parse_rfc3339(log_data["timestamp"].as_s),
        level: log_data["level"].as_s.to_sym,
        message: log_data["message"].as_s,
        source: log_data["source"]?.try(&.as_s),
        metadata: log_data["metadata"]?.try(&.as_h) || {} of String => JSON::Any
      )
    rescue
      nil
    end
  end
end
```

### Log Analytics

```crystal
class LogAnalytics
  def self.analyze_logs(log_file : String) : Hash(String, JSON::Any)
    log_entries = [] of LogEntry

    # Parse log file
    File.each_line(log_file) do |line|
      if entry = LogParser.parse_log_line(line)
        log_entries << entry
      end
    end

    # Analyze logs
    {
      "total_logs" => log_entries.size,
      "log_levels" => analyze_log_levels(log_entries),
      "error_rate" => calculate_error_rate(log_entries),
      "top_errors" => get_top_errors(log_entries),
      "performance_metrics" => analyze_performance_logs(log_entries)
    }
  end

  private def self.analyze_log_levels(entries : Array(LogEntry)) : Hash(String, Int32)
    level_counts = {} of String => Int32

    entries.each do |entry|
      level = entry.level.to_s
      level_counts[level] = (level_counts[level]? || 0) + 1
    end

    level_counts
  end

  private def self.calculate_error_rate(entries : Array(LogEntry)) : Float64
    error_count = entries.count { |entry| entry.level == :error }
    total_count = entries.size

    return 0.0 if total_count == 0
    error_count.to_f / total_count
  end

  private def self.get_top_errors(entries : Array(LogEntry)) : Array(Hash(String, JSON::Any))
    error_messages = entries
      .select { |entry| entry.level == :error }
      .map(&.message)
      .tally
      .sort_by { |_, count| -count }
      .first(10)

    error_messages.map do |message, count|
      {
        "message" => JSON::Any.new(message),
        "count" => JSON::Any.new(count)
      }
    end
  end
end
```

## Best Practices

### 1. Use Structured Logging

```crystal
# Good: Structured logging
Log.info { {
  message: "User created",
  user_id: user.id,
  email: user.email,
  timestamp: Time.utc.to_rfc3339
}.to_json }

# Avoid: Unstructured logging
Log.info { "User created: #{user.id} - #{user.email}" }
```

### 2. Include Context

```crystal
# Good: Include context
Log.info { {
  message: "Request processed",
  request_id: request_id,
  user_id: user_id,
  duration_ms: duration.total_milliseconds
}.to_json }

# Avoid: Missing context
Log.info { "Request processed" }
```

### 3. Use Appropriate Log Levels

```crystal
# Good: Appropriate log levels
Log.debug { "Debug information" }
Log.info { "User action" }
Log.warn { "Potential issue" }
Log.error { "Error occurred" }

# Avoid: Wrong log levels
Log.error { "User logged in" }  # Should be info
Log.info { "Critical error" }   # Should be error
```

### 4. Handle Log Failures Gracefully

```crystal
# Good: Handle log failures
def log_with_fallback(message : String)
  begin
    Log.info { message }
  rescue e
    # Fallback to console
    puts "Log failed: #{e.message}"
  end
end

# Avoid: Ignoring log failures
# No error handling - can cause application crashes
```

### 5. Monitor Log Performance

```crystal
# Good: Monitor log performance
class LogPerformanceMonitor
  def self.record_log_performance(level : Log::Severity, duration : Time::Span)
    Azu.cache.increment("metrics:log_performance:#{level}")
    Azu.cache.set("metrics:log_performance:#{level}:last", duration.total_milliseconds)
  end
end

# Avoid: No log performance monitoring
# No monitoring - can't identify log performance issues
```

## Next Steps

Now that you understand async logging:

1. **[Performance](performance.md)** - Optimize logging performance
2. **[Monitoring](monitoring.md)** - Monitor log performance
3. **[Testing](../testing.md)** - Test logging functionality
4. **[Deployment](../deployment/production.md)** - Deploy with logging
5. **[Security](../advanced/security.md)** - Implement secure logging

---

_Async logging in Azu provides high-performance, non-blocking log processing that ensures your application remains responsive. With structured logging, multiple outputs, and performance optimization, it's essential for production applications._

# Async Logging System

Azu provides a sophisticated asynchronous logging system with structured data, batch processing, and background error reporting. This system is designed for high-performance applications that need reliable, non-blocking logging.

## Overview

The async logging system consists of several components:

- **Structured Log Entries**: Rich metadata with timestamps, severity, context, and request tracing
- **Batch Processing**: Efficient processing of log entries in batches to reduce I/O overhead
- **Background Error Reporting**: Dedicated error processing pipeline with external service integration
- **Request Tracing**: Automatic request ID generation and correlation across log entries

## Basic Usage

### Simple Async Logging

```crystal
# Create an async logger
logger = Azu::AsyncLogging::AsyncLogger.new("my_app")

# Log messages with context
logger.info("User logged in", {
  "user_id" => "123",
  "ip_address" => "192.168.1.1"
})

logger.error("Database connection failed", {
  "database" => "users_db",
  "retry_count" => "3"
}, database_exception)
```

### Request-Scoped Logging

```crystal
class MyEndpoint
  include Endpoint(MyRequest, MyResponse)

  get "/api/users/:id"

  def call : MyResponse
    # Create logger with request ID for tracing
    logger = AsyncLogging::AsyncLogger.new("users_api")
      .with_request_id(context.request.headers["X-Request-ID"]?)

    logger.info("Processing user request", {
      "user_id" => @request.id,
      "method" => "GET"
    })

    # Your endpoint logic here
    user = fetch_user(@request.id)

    logger.info("User request completed", {
      "user_id" => @request.id,
      "status" => "success"
    })

    MyResponse.new(user)
  rescue ex
    logger.error("User request failed", {
      "user_id" => @request.id,
      "error_type" => ex.class.name
    }, ex)
    raise ex
  end
end
```

## Advanced Features

### Batch Processing Configuration

The batch processor automatically groups log entries for efficient processing:

```crystal
# Configure batch processing (in your app initialization)
class MyApp
  def self.configure_logging
    # The system automatically:
    # - Processes logs in batches of 50 entries
    # - Flushes every 5 seconds
    # - Uses 4 worker threads
    # - Groups by severity for optimal processing
  end
end
```

### Error Reporting

Errors are automatically processed through a dedicated pipeline:

```crystal
# Manual error reporting
begin
  risky_operation
rescue ex
  # Report to background error processor
  AsyncLogging::ErrorReporter.report_error(ex)

  # Also log with context
  logger.error("Operation failed", {
    "operation" => "risky_operation",
    "attempt" => "1"
  }, ex)
end
```

### External Service Integration

The system supports integration with external logging services:

```crystal
# Example: Sentry integration (implement in your app)
class SentryIntegration
  def self.send_batch(batch : Array(AsyncLogging::LogEntry))
    batch.each do |entry|
      if entry.severity.error? || entry.severity.fatal?
        Sentry.capture_exception(entry.exception) if entry.exception
      end
    end
  end
end

# Example: DataDog integration
class DataDogIntegration
  def self.send_batch(batch : Array(AsyncLogging::LogEntry))
    batch.each do |entry|
      DataDog.log(
        entry.message,
        level: entry.severity.to_s,
        tags: entry.context.try(&.keys.map { |k| "#{k}:#{entry.context[k]}" })
      )
    end
  end
end
```

## Performance Benefits

### Non-Blocking Operations

```crystal
# Before: Blocking synchronous logging
def process_request
  # This blocks the request thread
  Log.info { "Processing request" }

  # Request processing...
  result = expensive_operation

  # This also blocks
  Log.info { "Request completed" }
  result
end

# After: Non-blocking async logging
def process_request
  logger = AsyncLogging::AsyncLogger.new("api")

  # This doesn't block the request thread
  logger.info("Processing request")

  # Request processing continues immediately
  result = expensive_operation

  # This also doesn't block
  logger.info("Request completed")
  result
end
```

### Batch Processing Efficiency

```crystal
# The system automatically batches similar log entries:
# Instead of 100 individual log writes:
# 100 * 1ms = 100ms total

# The system processes them in batches:
# 2 batches * 5ms = 10ms total
# 90% performance improvement
```

## Configuration

### Environment Variables

```bash
# Logging configuration
CRYSTAL_ENV=production
LOG_LEVEL=info
LOG_BATCH_SIZE=50
LOG_FLUSH_INTERVAL=5
LOG_WORKERS=4
```

### Custom Configuration

```crystal
class CustomLoggingConfig
  def self.setup
    # Custom batch size
    AsyncLogging::BatchProcessor.class_variable_set(:@@batch_size, 100)

    # Custom flush interval
    AsyncLogging::BatchProcessor.class_variable_set(:@@flush_interval, 10.seconds)

    # Custom worker count
    AsyncLogging::BatchProcessor.class_variable_set(:@@workers, 8)
  end
end
```

## Monitoring and Debugging

### Health Checks

```crystal
class LoggingHealthCheck
  def self.status : Hash(String, String)
    {
      "batch_processor_running" => AsyncLogging::BatchProcessor.running?.to_s,
      "error_reporter_running" => AsyncLogging::ErrorReporter.running?.to_s,
      "queue_size" => AsyncLogging::BatchProcessor.queue_size.to_s
    }
  end
end
```

### Metrics Collection

```crystal
class LoggingMetrics
  def self.collect : Hash(String, Int64)
    {
      "logs_processed" => AsyncLogging::BatchProcessor.processed_count,
      "errors_reported" => AsyncLogging::ErrorReporter.reported_count,
      "batch_flushes" => AsyncLogging::BatchProcessor.flush_count
    }
  end
end
```

## Best Practices

### 1. Use Structured Context

```crystal
# Good: Rich context for debugging
logger.info("User action", {
  "user_id" => user.id,
  "action" => "profile_update",
  "ip_address" => request.remote_address,
  "user_agent" => request.headers["User-Agent"]
})

# Avoid: Minimal context
logger.info("User did something")
```

### 2. Request Tracing

```crystal
# Always use request IDs for tracing
logger = AsyncLogging::AsyncLogger.new("api")
  .with_request_id(request.headers["X-Request-ID"]?)

# All log entries will include the request ID for correlation
```

### 3. Error Handling

```crystal
# Good: Comprehensive error logging
begin
  risky_operation
rescue ex : DatabaseError
  logger.error("Database operation failed", {
    "operation" => "user_create",
    "retry_count" => retry_count.to_s
  }, ex)

  # Also report to error service
  AsyncLogging::ErrorReporter.report_error(ex)
rescue ex : ValidationError
  logger.warn("Validation failed", {
    "field" => ex.field,
    "value" => ex.value
  })
end
```

### 4. Performance Monitoring

```crystal
# Log performance metrics
start_time = Time.monotonic

# ... operation ...

elapsed = Time.monotonic - start_time
logger.info("Operation completed", {
  "operation" => "database_query",
  "duration_ms" => elapsed.total_milliseconds.to_s,
  "rows_returned" => result.size.to_s
})
```

## Migration from Synchronous Logging

### Before (Synchronous)

```crystal
class OldLogger
  def call(context)
    Log.info { "Request started" }

    call_next(context)

    Log.info { "Request completed" }
  end
end
```

### After (Asynchronous)

```crystal
class NewLogger
  def call(context)
    logger = AsyncLogging::AsyncLogger.new("http")
      .with_request_id(generate_request_id(context))

    logger.info("Request started")

    call_next(context)

    logger.info("Request completed")
  end
end
```

## Troubleshooting

### Common Issues

1. **Queue Overflow**: If the log queue fills up, the system falls back to synchronous logging
2. **Worker Failures**: Failed workers are automatically restarted
3. **External Service Failures**: External service failures don't affect local logging

### Debug Mode

```crystal
# Enable debug logging for the async system
Log.setup(:debug, Log::IOBackend.new(formatter: LogFormat))

# Monitor the async logging system
AsyncLogging::BatchProcessor.debug_mode = true
```

This async logging system provides enterprise-grade logging capabilities while maintaining high performance and reliability for your Azu applications.

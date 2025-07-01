# Development Dashboard

The Azu Development Dashboard provides comprehensive real-time insights into your application's performance, metrics, and runtime behavior. It's designed specifically for development environments to help you optimize and debug your Azu applications.

## Overview

The Development Dashboard is a built-in HTTP handler that displays:

- **Application Status** - Uptime, memory usage, request counts, error rates
- **Performance Metrics** - Response times, throughput, memory allocation patterns
- **Cache Statistics** - Hit rates, operation breakdowns, data volume metrics
- **Component Lifecycle** - Mount/unmount events, refresh patterns, memory usage
- **Error Logs** - Recent errors with detailed debugging information
- **Route Listing** - All registered routes with their handlers
- **System Information** - Crystal version, GC stats, process information
- **Test Results** - Code coverage, test suite performance (mocked)

## Quick Start

### Basic Setup

Add the DevDashboard handler to your middleware stack:

```crystal
require "azu"

module MyApp
  include Azu

  configure do
    # Enable performance monitoring
    performance_monitor = Handler::PerformanceMonitor.new
  end
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::DevDashboard.new,        # Add this line
  MyApp::CONFIG.performance_monitor.not_nil!,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
```

### Accessing the Dashboard

Once your application is running, visit:

```
http://localhost:4000/dev-dashboard
```

The dashboard automatically refreshes every 30 seconds to show live data.

## Configuration

### Custom Dashboard Path

```crystal
# Use a custom path for the dashboard
dashboard = Azu::Handler::DevDashboard.new(path: "/admin/dev-metrics")

MyApp.start [
  dashboard,
  # other handlers...
]
```

### Custom Performance Metrics

```crystal
# Use a custom metrics instance
custom_metrics = Azu::PerformanceMetrics.new
dashboard = Azu::Handler::DevDashboard.new(metrics: custom_metrics)

MyApp.start [
  dashboard,
  # other handlers...
]
```

### Environment-Specific Setup

```crystal
module MyApp
  include Azu

  configure do
    case env
    when .development?
      performance_monitor = Handler::PerformanceMonitor.new
    when .production?
      # Disable dashboard in production
      performance_monitor = nil
    end
  end
end

handlers = [
  Azu::Handler::RequestId.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]

# Only add dashboard in development
if MyApp::CONFIG.env.development?
  dashboard = Azu::Handler::DevDashboard.new
  handlers.insert(1, dashboard)  # Insert after RequestId
end

if monitor = MyApp::CONFIG.performance_monitor
  handlers.insert(-2, monitor)  # Insert before Logger
end

MyApp.start(handlers)
```

## Dashboard Features

### 1. Application Status

Displays real-time application health metrics:

- **Uptime**: How long the application has been running
- **Memory Usage**: Current memory consumption in MB
- **Total Requests**: Number of requests processed since startup
- **Error Rate**: Percentage of requests that resulted in errors
- **CPU Usage**: Current CPU utilization (mocked)

### 2. Performance Metrics

Shows detailed performance statistics collected from the PerformanceMetrics module:

- **Average Response Time**: Mean request processing time
- **P95/P99 Response Times**: 95th and 99th percentile response times
- **Requests per Second**: Current throughput
- **Peak Memory Usage**: Highest memory delta recorded
- **Memory Allocation Patterns**: Memory usage trends

### 3. Cache Metrics

Comprehensive caching performance data:

- **Hit Rate**: Cache effectiveness percentage
- **Operation Breakdown**: GET, SET, DELETE operation statistics
- **Processing Times**: Average time per cache operation
- **Data Volume**: Amount of data written to cache
- **Error Rates**: Cache operation failure rates

Example cache integration:

```crystal
# Your endpoint using cache
struct UserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  get "/users/:id"

  def call : UserResponse
    user_id = params["id"]

    # Cache operations are automatically tracked
    user_data = Azu.cache.fetch("user:#{user_id}", ttl: 1.hour) do
      User.find(user_id).to_json
    end

    UserResponse.new(user_data)
  end
end
```

### 4. Component Lifecycle

Tracks real-time component behavior:

- **Total Components**: Number of active components
- **Mount/Unmount Events**: Component creation and destruction
- **Refresh Events**: Component update frequency
- **Average Component Age**: How long components stay active

Example component with tracking:

```crystal
class UserListComponent < Azu::Component
  def initialize(@users : Array(User))
    super
    # Component lifecycle is automatically tracked
  end

  def content
    div class: "user-list" do
      @users.each do |user|
        UserCardComponent.new(user).render
      end
    end
  end

  def on_event("refresh", data)
    @users = User.all  # Refresh events are tracked
    refresh
  end
end
```

### 5. Error Logs

Recent application errors with detailed information:

- **Timestamp**: When the error occurred
- **HTTP Method and Path**: Request details
- **Status Code**: Error type (4xx/5xx)
- **Processing Time**: How long the failed request took
- **Endpoint**: Which handler processed the request
- **Memory Impact**: Memory usage during the error

### 6. Route Listing

Displays all registered application routes:

- **HTTP Method**: GET, POST, PUT, DELETE, etc.
- **Path Pattern**: URL patterns with parameters
- **Handler Class**: Which endpoint handles the route
- **Description**: Route purpose (when available)

### 7. System Information

Runtime environment details:

- **Crystal Version**: Language version in use
- **Environment**: Development, production, test
- **Process ID**: Current process identifier
- **GC Statistics**: Garbage collection metrics
- **Heap Size**: Current memory heap size

## Dashboard Actions

### Clear Metrics

Reset all collected performance data:

```
http://localhost:4000/dev-dashboard?clear=true
```

Or use the "Clear Metrics" button in the dashboard interface.

### Generate Test Data

Use the development tools endpoint to populate the dashboard with sample data:

```crystal
# GET /dev-tools?action=generate_test_data
# This will create sample metrics for testing the dashboard
```

## API Integration

### Custom Metrics Collection

Integrate custom metrics into your endpoints:

```crystal
struct CustomEndpoint
  include Azu::Endpoint(CustomRequest, CustomResponse)

  get "/custom/:id"

  def call : CustomResponse
    # Custom metric recording
    if monitor = CONFIG.performance_monitor
      monitor.metrics.record_request(
        endpoint: "CustomEndpoint",
        method: "GET",
        path: "/custom/#{params["id"]}",
        processing_time: measure_time,
        memory_before: memory_before,
        memory_after: memory_after,
        status_code: 200
      )
    end

    CustomResponse.new("Custom response")
  end

  private def measure_time
    start = Time.monotonic
    yield
    (Time.monotonic - start).total_milliseconds
  end
end
```

### Cache Operation Tracking

Track custom cache operations:

```crystal
# Manual cache operation tracking
def custom_cache_operation(key : String, value : String)
  if monitor = CONFIG.performance_monitor
    Azu::PerformanceMetrics.time_cache_operation(
      monitor.metrics, key, "custom_set", "memory"
    ) do
      # Your cache operation
      cache.set(key, value)
    end
  else
    cache.set(key, value)
  end
end
```

## Development Tools Integration

### Test Data Generation

The dashboard works with the development tools endpoint to generate test data:

```crystal
# Generate sample metrics
GET /dev-tools?action=generate_test_data

# Simulate error scenarios
GET /dev-tools?action=simulate_errors

# Test cache operations
GET /dev-tools?action=cache_test

# Test component lifecycle
GET /dev-tools?action=component_test

# Clear all metrics
GET /dev-tools?action=clear_metrics
```

### Benchmarking Integration

Combine with Azu's benchmarking tools:

```crystal
# In your endpoint
def call : MyResponse
  benchmark_result = Azu::DevelopmentTools::Benchmark.run("my_operation") do
    expensive_operation()
  end

  # Results automatically appear in dashboard
  MyResponse.new(benchmark_result)
end
```

## Security Considerations

### Development Only

**Important**: The development dashboard should only be used in development environments:

```crystal
# Safe configuration
if ENV["CRYSTAL_ENV"]? == "development"
  handlers << Azu::Handler::DevDashboard.new
end

# Or use environment detection
if CONFIG.env.development?
  handlers << Azu::Handler::DevDashboard.new
end
```

### Access Control

Add authentication if needed:

```crystal
class SecureDevDashboard < Azu::Handler::DevDashboard
  def call(context : HTTP::Server::Context)
    # Only allow localhost access
    remote_address = context.request.remote_address
    unless remote_address.is_a?(Socket::IPAddress) && remote_address.loopback?
      context.response.status_code = 403
      context.response.print("Dashboard access denied")
      return
    end

    super(context)
  end
end

# Use the secure version
handlers << SecureDevDashboard.new
```

## Performance Impact

The dashboard has minimal performance impact:

- **Memory**: Maintains a rolling window of recent metrics (max 10,000 entries)
- **CPU**: Metrics collection adds ~0.1ms per request
- **Storage**: All data is in-memory, no persistence

### Optimization

For high-traffic applications:

```crystal
# Reduce metrics collection
monitor = Azu::Handler::PerformanceMonitor.new
monitor.enabled = false  # Disable during load tests

# Or use sampling
class SamplingDashboard < Azu::Handler::DevDashboard
  def call(context : HTTP::Server::Context)
    # Only collect metrics for 10% of requests
    if Random.rand < 0.1
      super(context)
    else
      call_next(context)
    end
  end
end
```

## Troubleshooting

### Dashboard Not Loading

1. **Check Handler Order**: DevDashboard should be early in the middleware stack
2. **Verify Path**: Default path is `/dev-dashboard`
3. **Check Environment**: Ensure you're in development mode

### Missing Metrics

1. **Performance Monitor**: Ensure PerformanceMonitor is in the handler stack
2. **Enable Monitoring**: Check that monitoring is enabled
3. **Generate Data**: Use development tools to create test metrics

### Route Information Missing

If routes aren't showing:

1. **Router Method**: Ensure your router has the `route_info` method
2. **Route Registration**: Verify routes are registered properly
3. **Check Logs**: Look for route collection error messages

## Best Practices

### 1. Development Workflow

```crystal
# Use in development setup
module MyApp
  include Azu

  configure do
    if env.development?
      # Enable all development tools
      performance_monitor = Handler::PerformanceMonitor.new
      template_hot_reload = true
      cache_config.enabled = false  # Disable cache in dev
    end
  end
end
```

### 2. Debugging Performance

1. **Use P95/P99 metrics** instead of averages for performance analysis
2. **Monitor memory deltas** to identify memory leaks
3. **Check error logs** for patterns in failures
4. **Use cache metrics** to optimize caching strategies

### 3. Component Development

1. **Monitor component lifecycle** to optimize mounting/unmounting
2. **Track refresh patterns** to reduce unnecessary updates
3. **Use memory metrics** to identify component memory leaks

## Extensions

### Custom Dashboard Sections

Extend the dashboard with custom metrics:

```crystal
class ExtendedDevDashboard < Azu::Handler::DevDashboard
  private def collect_dashboard_data
    data = super

    # Add custom section
    data["custom_metrics"] = {
      "database_connections" => get_db_connection_count,
      "queue_size" => get_background_queue_size,
      "external_api_calls" => get_api_call_count
    }

    data
  end

  private def get_db_connection_count
    # Your custom metric collection
    42
  end
end
```

### JSON API Endpoint

Create a JSON API for the dashboard data:

```crystal
struct DashboardApiEndpoint
  include Azu::Endpoint(EmptyRequest, JsonResponse)

  get "/api/dashboard"

  def call : JsonResponse
    dashboard = Azu::Handler::DevDashboard.new
    data = dashboard.collect_dashboard_data
    JsonResponse.new(data)
  end
end
```

## Next Steps

- [Performance Monitoring Guide](../performance/monitoring.md)
- [Caching Strategies](../advanced/caching.md)
- [Component Development](../real-time/components.md)
- [Benchmarking and Profiling](../performance/optimization.md)

---

The Development Dashboard is a powerful tool for understanding your Azu application's behavior. Use it during development to optimize performance, debug issues, and gain insights into your application's runtime characteristics.

# Development Dashboard

The Azu Development Dashboard provides comprehensive real-time insights into your application's performance, metrics, and runtime behavior. It's designed specifically for development environments to help you optimize and debug your Azu applications.

> **⚠️ Important**: The Development Dashboard requires **Performance Monitoring** to be enabled for full functionality. Performance monitoring in Azu is completely optional and disabled by default for zero overhead in production.

## Prerequisites

### Enable Performance Monitoring

The development dashboard depends on performance metrics collection for most features. You must enable performance monitoring:

**Environment Variable:**

```bash
export PERFORMANCE_MONITORING=true
export PERFORMANCE_PROFILING=true        # Optional: Detailed profiling
export PERFORMANCE_MEMORY_MONITORING=true # Optional: Memory tracking
```

**Compile-time Flag:**

```bash
crystal build --define=performance_monitoring src/app.cr
```

**Configuration:**

```crystal
Azu.configure do |config|
  config.performance_enabled = true
  config.performance_profiling_enabled = true
  config.performance_memory_monitoring = true
end
```

## Overview

The Development Dashboard is a built-in HTTP handler that displays:

### Always Available (No Performance Monitoring Required)

- **Route Listing** - All registered routes with their handlers
- **System Information** - Crystal version, GC stats, process information
- **Basic Application Status** - Uptime, memory usage, process information

### Requires Performance Monitoring

- **Performance Metrics** - Response times, throughput, memory allocation patterns
- **Cache Statistics** - Hit rates, operation breakdowns, data volume metrics
- **Component Lifecycle** - Mount/unmount events, refresh patterns, memory usage
- **Error Logs** - Recent errors with detailed debugging information
- **Advanced Application Status** - Request counts, error rates, CPU usage

## Dashboard Preview

![Azu Development Dashboard](../.gitbook/assets/dev-dashboard-full-dark.png)

_The Azu Development Dashboard featuring sidebar navigation, Golden Signals monitoring, health score visualization, and comprehensive metrics._

### Key Visual Features:

- **Sidebar Navigation**: Quick access to Overview, Errors, Requests, Database, Cache, Routes, and Components
- **Health Score Ring**: At-a-glance application health indicator (0-100 score)
- **Golden Signals Panel**: SRE-standard monitoring (Latency, Traffic, Errors, Saturation)
- **Alert Banner**: Critical and warning issues requiring attention
- **Insights Panel**: Smart recommendations based on detected patterns
- **Comprehensive Metrics**: Application status, performance data, cache statistics
- **Error Tracking**: Recent error logs with detailed debugging information
- **Database Monitoring**: N+1 query detection, slow query analysis
- **Route Discovery**: Complete listing of all registered application routes
- **Component Lifecycle**: Mount/unmount events with memory tracking
- **Keyboard Shortcuts**: Navigate with `g o`, `g e`, `g d`, etc.
- **Theme Support**: Light, dark, and system theme options

> **Visual Guide**: For a detailed visual walkthrough with screenshots of each section, see the [Development Dashboard Visual Guide](development-dashboard-visual-guide.md).

## Quick Start

### With Performance Monitoring (Recommended for Development)

```crystal
require "azu"

module MyApp
  include Azu

  configure do
    # Performance monitoring must be enabled at compile time
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      performance_monitor = Handler::PerformanceMonitor.new
    {% end %}
  end
end

# Conditional handler chain based on performance monitoring
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  MyApp.start [
    Azu::Handler::RequestId.new,
    Azu::Handler::DevDashboard.new,              # Full dashboard functionality
    MyApp::CONFIG.performance_monitor.not_nil!,  # Required for metrics
    Azu::Handler::Rescuer.new,
    Azu::Handler::Logger.new,
  ]
{% else %}
  MyApp.start [
    Azu::Handler::RequestId.new,
    Azu::Handler::DevDashboard.new,              # Limited functionality
    Azu::Handler::Rescuer.new,
    Azu::Handler::Logger.new,
  ]
{% end %}
```

### Without Performance Monitoring (Limited Functionality)

```crystal
require "azu"

module MyApp
  include Azu
end

MyApp.start [
  Azu::Handler::RequestId.new,
  Azu::Handler::DevDashboard.new,  # Shows basic info only
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

### Environment-Specific Setup

```crystal
module MyApp
  include Azu

  configure do
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      case env
      when .development?
        performance_monitor = Handler::PerformanceMonitor.new
      when .production?
        # Production can still use monitoring if explicitly enabled
        performance_monitor = Handler::PerformanceMonitor.new
      end
    {% end %}
  end
end

# Production-safe configuration
{% if env("CRYSTAL_ENV") == "development" %}
  handlers = [
    Azu::Handler::RequestId.new,
    Azu::Handler::DevDashboard.new,  # Only in development
  ]

  {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
    handlers << MyApp::CONFIG.performance_monitor.not_nil!
  {% end %}

  handlers.concat([
    Azu::Handler::Rescuer.new,
    Azu::Handler::Logger.new,
  ])
{% else %}
  handlers = [
    Azu::Handler::RequestId.new,
    Azu::Handler::Rescuer.new,
    Azu::Handler::Logger.new,
  ]
{% end %}

MyApp.start(handlers)
```

### Custom Dashboard Path

```crystal
# Use a custom path for the dashboard
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  dashboard = Azu::Handler::DevDashboard.new(
    path: "/admin/dev-metrics",
    metrics: MyApp::CONFIG.performance_monitor.try(&.metrics)
  )
{% else %}
  dashboard = Azu::Handler::DevDashboard.new(path: "/admin/dev-metrics")
{% end %}

MyApp.start [
  dashboard,
  # other handlers...
]
```

## Dashboard Features by Mode

### Full Mode (PERFORMANCE_MONITORING=true)

**1. Application Status**

- ✅ Uptime, memory usage, process information
- ✅ Total requests processed since startup
- ✅ Error rate percentage with color coding
- ✅ CPU usage tracking

**2. Performance Metrics**

- ✅ Average, P95, P99 response times
- ✅ Requests per second throughput
- ✅ Peak memory usage and allocation patterns
- ✅ Memory delta tracking

**3. Cache Metrics**

- ✅ Hit rate percentage
- ✅ Operation breakdown (GET, SET, DELETE)
- ✅ Processing times per operation
- ✅ Data volume and error rates

**4. Component Lifecycle**

- ✅ Total active components
- ✅ Mount/unmount/refresh event tracking
- ✅ Average component age
- ✅ Memory usage per component

**5. Error Logs**

- ✅ Recent errors with timestamps
- ✅ Processing time and memory impact
- ✅ Endpoint and error classification

### Limited Mode (PERFORMANCE_MONITORING=false)

**1. Application Status**

- ✅ Uptime, memory usage, process information
- ⚠️ Request counts show "N/A"
- ⚠️ Error rates show "Enable monitoring"

**2. Performance Metrics**

- ⚠️ Shows "Performance monitoring disabled"
- ⚠️ Instructions to enable monitoring

**3. Cache Metrics**

- ✅ Cache store type and basic configuration
- ⚠️ Hit rates and operation stats unavailable

**4. Component Lifecycle**

- ✅ Basic component registry information
- ⚠️ No performance tracking data

**5. Error Logs**

- ⚠️ Basic error information only
- ⚠️ No performance correlation

**6. Route Listing** (Always Available)

- ✅ All registered routes with methods
- ✅ Handler class information
- ✅ Path patterns with parameters

**7. System Information** (Always Available)

- ✅ Crystal version and environment
- ✅ Process ID and GC statistics
- ✅ Heap size information

## Golden Signals Monitoring

The dashboard implements Google SRE's Four Golden Signals for comprehensive monitoring:

### Latency

Tracks request response times with percentile breakdowns:

- **Average Response Time** - Mean duration across all requests
- **P50/P95/P99** - Percentile distribution for understanding tail latency
- **Sparkline Visualization** - Visual trend over recent requests

| Status | Threshold |
|--------|-----------|
| Healthy | < 100ms average |
| Warning | 100-500ms average |
| Critical | > 500ms average |

### Traffic

Monitors request volume and throughput:

- **Requests/Second** - Current throughput rate
- **Total Requests** - Cumulative count since startup
- **Sparkline Visualization** - Request volume trends

### Errors

Tracks error rates and counts:

- **Error Rate** - Percentage of failed requests (4xx/5xx)
- **Error Count** - Absolute count in recent window

| Status | Threshold |
|--------|-----------|
| Healthy | < 1% error rate |
| Warning | 1-5% error rate |
| Critical | > 5% error rate |

### Saturation

Monitors resource utilization:

- **Memory %** - Current memory utilization
- **GC Heap** - Garbage collector heap size
- **Progress Bar** - Visual utilization indicator

| Status | Threshold |
|--------|-----------|
| Healthy | < 70% memory |
| Warning | 70-85% memory |
| Critical | > 85% memory |

## Health Score System

The Health Score Ring provides an at-a-glance indicator of application health on a 0-100 scale:

### Score Calculation

The score starts at 100 and deductions are applied based on:

| Factor | Maximum Deduction |
|--------|-------------------|
| Error rate | -30 points |
| Average response time | -20 points |
| Cache hit rate | -15 points |
| N+1 query patterns | -15 points |
| Slow queries | -10 points |

### Score Ranges

| Score | Status | Color | Meaning |
|-------|--------|-------|---------|
| 90-100 | Healthy | Green | All systems operating normally |
| 70-89 | Warning | Yellow | Some issues need attention |
| 0-69 | Critical | Red | Significant problems detected |

## Keyboard Shortcuts

Navigate the dashboard efficiently with keyboard shortcuts. Press `?` to view all shortcuts.

### Navigation

| Keys | Action |
|------|--------|
| `g` then `o` | Go to Overview |
| `g` then `e` | Go to Errors |
| `g` then `q` | Go to Requests |
| `g` then `d` | Go to Database |
| `g` then `c` | Go to Cache |
| `g` then `r` | Go to Routes |
| `g` then `p` | Go to Components |

### Actions

| Key | Action |
|-----|--------|
| `r` | Refresh data |
| `/` | Focus search |
| `e` | Export metrics |
| `?` | Show shortcuts modal |
| `Esc` | Close modal |

## Theme Support

The dashboard supports three theme options, accessible via the sidebar footer:

| Theme | Icon | Description |
|-------|------|-------------|
| Light | Sun | Clean light background for bright environments |
| Dark | Moon | Rich dark theme with blue undertones (default) |
| System | Monitor | Automatically follows OS preference |

Theme preference is persisted in localStorage and restored on page load.

## API Integration

### Safe Metrics Collection

Always check if performance monitoring is available:

```crystal
struct CustomEndpoint
  include Azu::Endpoint(CustomRequest, CustomResponse)

  get "/custom/:id"

  def call : CustomResponse
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      # Custom metric recording only when available
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
    {% end %}

    CustomResponse.new("Custom response")
  end
end
```

### Conditional Cache Operation Tracking

```crystal
def custom_cache_operation(key : String, value : String)
  {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
    if monitor = CONFIG.performance_monitor
      Azu::PerformanceMetrics.time_cache_operation(
        monitor.metrics, key, "custom_set", "memory"
      ) do
        cache.set(key, value)
      end
    else
      cache.set(key, value)
    end
  {% else %}
    cache.set(key, value)
  {% end %}
end
```

### Component Performance Tracking

```crystal
class UserListComponent < Azu::Component
  def initialize(@users : Array(User))
    super
    # Enable performance tracking only when monitoring is available
    {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
      enable_performance_tracking
    {% end %}
  end

  def content
    div class: "user-list" do
      @users.each do |user|
        UserCardComponent.new(user).render
      end
    end
  end

  def on_event("refresh", data)
    @users = User.all
    refresh  # Tracking happens automatically if enabled
  end
end
```

## Development Tools Integration

### Test Data Generation

The dashboard works with development tools (when performance monitoring is enabled):

```crystal
# Generate sample metrics (only works with monitoring enabled)
GET /dev-tools?action=generate_test_data

# Simulate error scenarios
GET /dev-tools?action=simulate_errors

# Clear all metrics
GET /dev-tools?action=clear_metrics
```

### Environment-Based Tools

```bash
# Development with full monitoring
CRYSTAL_ENV=development PERFORMANCE_MONITORING=true crystal run src/app.cr

# Development with basic dashboard
CRYSTAL_ENV=development PERFORMANCE_MONITORING=false crystal run src/app.cr

# Production (no dashboard)
CRYSTAL_ENV=production crystal build --release src/app.cr
```

## Security Considerations

### Environment-Based Access Control

```crystal
# Safe configuration for all environments
{% if env("CRYSTAL_ENV") == "development" %}
  {% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
    handlers << Azu::Handler::DevDashboard.new  # Full dashboard
  {% else %}
    handlers << Azu::Handler::DevDashboard.new  # Basic dashboard
  {% end %}
{% end %}
```

### Production Safety

```crystal
class SecureDevDashboard < Azu::Handler::DevDashboard
  def call(context : HTTP::Server::Context)
    # Only allow in development
    unless Azu::CONFIG.env.development?
      context.response.status_code = 404
      return
    end

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
```

## Performance Impact

### With Performance Monitoring Enabled

- **Memory**: ~2-5MB for metrics storage (rolling window)
- **CPU**: <1% overhead for metrics collection
- **Storage**: In-memory only, max 10,000 entries

### With Performance Monitoring Disabled (Default)

- **Memory**: 0 bytes (no metrics collection)
- **CPU**: 0% overhead (code not compiled)
- **Storage**: No metrics collection

### Dashboard-Only Impact

- **Memory**: Minimal (dashboard rendering only)
- **CPU**: <0.1% for dashboard rendering
- **Network**: HTML response for dashboard requests

## Troubleshooting

### Dashboard Shows "Monitoring Disabled"

**Problem**: Most metrics show "N/A" or disabled messages
**Solution**: Enable performance monitoring

```bash
export PERFORMANCE_MONITORING=true
crystal run src/app.cr
```

### Performance Monitor is Nil

**Problem**: `CONFIG.performance_monitor.not_nil!` crashes
**Solution**: Use conditional access

```crystal
{% if env("PERFORMANCE_MONITORING") == "true" || flag?(:performance_monitoring) %}
  if monitor = CONFIG.performance_monitor
    # Use monitor safely
  end
{% end %}
```

### Dashboard Not Loading

1. **Check Environment**: Verify dashboard is included for your environment
2. **Check Path**: Default path is `/dev-dashboard`
3. **Handler Order**: DevDashboard should be early in middleware stack

### Missing Route Information

If routes aren't showing:

1. **Router Integration**: Routes are always available (no monitoring required)
2. **Route Registration**: Verify routes are registered properly
3. **Handler Chain**: Ensure endpoints are properly configured

## Best Practices

### Development Environment

1. **Always enable monitoring**: `PERFORMANCE_MONITORING=true`
2. **Use full profiling**: Enable all tracking features
3. **Regular review**: Check dashboard frequently during development
4. **Test with realistic data**: Use development tools to generate metrics

### Staging Environment

1. **Optional monitoring**: Enable for performance testing only
2. **Limited dashboard**: Consider basic dashboard without full monitoring
3. **Load testing**: Use dashboard during stress tests
4. **Performance validation**: Verify optimizations work

### Production Environment

1. **Disable dashboard**: Remove from production builds
2. **No monitoring overhead**: Use default `PERFORMANCE_MONITORING=false`
3. **External monitoring**: Use dedicated APM tools for production
4. **Security**: Never expose dashboard in production

---

The Development Dashboard provides powerful insights when you need them, with zero overhead when you don't. Whether you're debugging performance issues with full monitoring or just need basic route information, the dashboard adapts to your configuration automatically.

**Get started**: Set `PERFORMANCE_MONITORING=true` and visit `/dev-dashboard`! 🚀

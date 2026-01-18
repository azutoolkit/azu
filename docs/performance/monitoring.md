# Performance Monitoring and Development Tools

Azu provides comprehensive performance monitoring and development tools to help you optimize your application's performance, detect memory leaks, and profile code execution.

## Overview

The performance monitoring system includes:

- **Request Processing Time Tracking** - Automatic tracking of endpoint response times
- **Memory Usage per Endpoint** - Monitor memory allocation and usage patterns
- **Component Lifecycle Metrics** - Track component mount, unmount, and refresh performance
- **Error Rate Monitoring** - Track and analyze application errors
- **Built-in Profiler** - Profile specific code blocks for optimization
- **Memory Leak Detection** - Detect and analyze potential memory leaks
- **Performance Benchmarking** - Compare different implementations and measure performance

## Configuration

### Environment Variables

Configure performance monitoring through environment variables:

```bash
# Enable/disable performance monitoring (default: true)
PERFORMANCE_MONITORING=true

# Enable profiling in development (default: false, auto-enabled in development)
PERFORMANCE_PROFILING=true

# Enable memory monitoring (default: false, auto-enabled in development)
PERFORMANCE_MEMORY_MONITORING=true

# Performance thresholds
PERFORMANCE_SLOW_REQUEST_THRESHOLD=1000  # milliseconds
PERFORMANCE_MEMORY_THRESHOLD=10485760    # bytes (10MB)
```

### Application Configuration

```crystal
module MyApp
  include Azu

  configure do |config|
    # Performance monitoring is enabled by default
    config.performance_enabled = true
    config.performance_profiling_enabled = true
    config.performance_memory_monitoring = true
  end
end

# Add performance monitoring to your handler chain
MyApp.start [
  Azu::Handler::PerformanceMonitor.new,  # Add this for automatic tracking
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
```

## Performance Metrics

### Automatic Request Tracking

The `PerformanceMonitor` handler automatically tracks:

- Request processing time
- Memory usage before and after request processing
- Endpoint identification
- HTTP status codes
- Error rates

### Accessing Metrics

```crystal
# Get performance statistics
if monitor = Azu::CONFIG.performance_monitor
  stats = monitor.stats
  puts "Average response time: #{stats.avg_response_time}ms"
  puts "Error rate: #{stats.error_rate}%"
  puts "Peak memory usage: #{stats.peak_memory_usage}MB"
end

# Get endpoint-specific statistics
endpoint_stats = monitor.endpoint_stats("MyEndpoint")
puts "Endpoint average time: #{endpoint_stats["avg_response_time"]}ms"

# Generate a comprehensive report
report = monitor.generate_report
puts report
```

### Component Lifecycle Metrics

Components automatically track performance metrics for:

- Mount operations
- Unmount operations
- Refresh operations
- Event handler execution

```crystal
class MyComponent
  include Azu::Component

  def content
    # This will be automatically tracked
    h1 "Hello World"
  end

  def on_event(name, data)
    # Event handling is automatically profiled
    super
  end
end
```

## Development Tools

### Built-in Profiler

Profile specific code blocks to identify performance bottlenecks:

```crystal
# Profile a block of code
result = Azu::DevelopmentTools.profile("database_query") do
  # Your code here
  User.all.to_a
end

# Get profiler statistics
stats = Azu::DevelopmentTools.profiler.stats
puts stats["database_query"]

# Generate profiler report
report = Azu::DevelopmentTools.profiler.report
puts report
```

### Memory Leak Detection

Monitor memory usage over time to detect potential leaks:

```crystal
# Start memory monitoring (automatically started in development)
detector = Azu::DevelopmentTools.memory_detector
detector.start_monitoring(interval: 30.seconds)

# Take manual snapshots
snapshot = detector.take_snapshot

# Analyze potential leaks
analysis = detector.analyze_leak
if analysis.leak_detected?
  puts "Potential memory leak detected!"
  puts "Memory growth: #{analysis.memory_growth_mb}MB"
  puts "Suspected issues: #{analysis.suspected_leaks}"
end

# Generate memory report
puts detector.report
```

### Performance Benchmarking

Compare different implementations and measure performance:

```crystal
# Single benchmark
result = Azu::DevelopmentTools::Benchmark.run("string_operations", 1000) do
  str = ""
  100.times { str += "test" }
end

puts "Average time: #{result.avg_time.total_milliseconds}ms"
puts "Operations per second: #{result.ops_per_second}"

# Compare multiple approaches
benchmarks = {
  "string_concat" => ->{
    str = ""
    100.times { str += "test" }
  },
  "string_build" => ->{
    String.build do |s|
      100.times { s << "test" }
    end
  }
}

results = Azu::DevelopmentTools::Benchmark.compare(benchmarks, 500)
results.each do |result|
  puts "#{result.name}: #{result.avg_time.total_milliseconds}ms"
end
```

### Load Testing

Test endpoint performance under load:

```crystal
# Load test an endpoint
results = Azu::DevelopmentTools::Benchmark.load_test(
  url: "http://localhost:4000/api/users",
  concurrent: 10,
  requests: 1000,
  timeout: 30.seconds
)

puts "Requests per second: #{results["requests_per_second"]}"
puts "Average response time: #{results["avg_response_time_ms"]}ms"
puts "Error rate: #{results["failed_requests"] / results["total_requests"] * 100}%"
```

## API Endpoints

### Performance Metrics Endpoint

Access performance data via HTTP:

```crystal
struct PerformanceEndpoint
  include Azu::Endpoint(EmptyRequest, JsonResponse)

  get "/admin/performance"

  def call : JsonResponse
    monitor = Azu::CONFIG.performance_monitor
    return error("Performance monitoring disabled") unless monitor

    JsonResponse.new({
      "stats" => monitor.stats,
      "recent_requests" => monitor.recent_requests(20),
      "report" => monitor.generate_report
    })
  end
end
```

### Development Tools Endpoint

```crystal
struct DevToolsEndpoint
  include Azu::Endpoint(EmptyRequest, JsonResponse)

  get "/admin/dev-tools"

  def call : JsonResponse
    JsonResponse.new({
      "profiler" => {
        "enabled" => Azu::DevelopmentTools.profiler.enabled,
        "stats" => Azu::DevelopmentTools.profiler.stats,
        "report" => Azu::DevelopmentTools.profiler.report
      },
      "memory" => {
        "current_usage_mb" => Azu::PerformanceMetrics.current_memory_usage / 1024.0 / 1024.0,
        "detector_report" => Azu::DevelopmentTools.memory_detector.report
      }
    })
  end
end
```

## Best Practices

### Performance Monitoring

1. **Enable in Development**: Always enable performance monitoring during development to catch issues early
2. **Monitor in Production**: Use performance monitoring in production with appropriate thresholds
3. **Regular Analysis**: Regularly review performance reports to identify trends
4. **Component Optimization**: Use component metrics to optimize real-time features

### Profiling

1. **Profile Suspected Bottlenecks**: Focus profiling on areas you suspect are slow
2. **Use Realistic Data**: Profile with production-like data volumes
3. **Profile Different Scenarios**: Test various input sizes and conditions
4. **Compare Alternatives**: Use benchmarking to compare different implementations

### Memory Management

1. **Monitor Continuously**: Run memory monitoring in development environments
2. **Analyze Growth Patterns**: Look for steady memory growth over time
3. **Component Lifecycle**: Pay attention to component mount/unmount patterns
4. **GC Efficiency**: Monitor garbage collection effectiveness

### Benchmarking

1. **Warmup Runs**: Always include warmup runs in benchmarks
2. **Multiple Iterations**: Run enough iterations for statistical significance
3. **Realistic Conditions**: Benchmark under realistic application conditions
4. **Compare Fairly**: Ensure benchmarks compare equivalent functionality

## Integration Examples

### Custom Metrics

```crystal
# Custom endpoint with manual metrics
struct MyEndpoint
  include Azu::Endpoint(MyRequest, MyResponse)

  def call : MyResponse
    # Manual profiling for specific operations
    db_result = Azu::DevelopmentTools.profile("database_operation") do
      MyModel.complex_query
    end

    # The endpoint's overall performance is automatically tracked
    MyResponse.new(db_result)
  end
end
```

### Performance-Aware Components

```crystal
class PerformanceAwareComponent
  include Azu::Component

  def refresh
    # Components are automatically profiled, but you can add custom profiling
    Azu::DevelopmentTools.profile("complex_rendering") do
      super
    end
  end
end
```

## Troubleshooting

### Common Issues

1. **High Memory Usage**: Check component lifecycle and ensure proper cleanup
2. **Slow Requests**: Use profiling to identify bottlenecks within endpoints
3. **Memory Leaks**: Monitor long-running applications for steady memory growth
4. **Performance Degradation**: Use benchmarking to compare current vs. previous performance

### Debug Mode

Enable detailed performance logging:

```crystal
# Enable development mode for comprehensive monitoring
Azu::DevelopmentTools.enable_development_mode

# This enables:
# - Profiler
# - Memory monitoring
# - Enhanced component tracking
```

## Performance Impact

The performance monitoring system is designed to have minimal impact:

- **Request Overhead**: ~0.1-0.5ms per request
- **Memory Overhead**: ~10-50MB depending on history size
- **Profiler Overhead**: Only when enabled and actively profiling
- **Component Tracking**: Minimal overhead, only measures timestamps

For production deployments, consider:

- Reducing history size for memory-constrained environments
- Disabling detailed profiling unless actively debugging
- Using sampling for high-traffic applications

## Conclusion

Azu's performance monitoring and development tools provide comprehensive insights into your application's performance characteristics. Use these tools during development to optimize performance and in production to maintain application health and performance standards.

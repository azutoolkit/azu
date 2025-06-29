# Development Tools

Azu provides a comprehensive suite of development tools for performance analysis, profiling, memory leak detection, and benchmarking. These tools help developers optimize their applications during development and identify performance bottlenecks in production.

## Overview

The `Azu::DevelopmentTools` module includes three main components:

- **Profiler** - Profile code execution time and memory usage
- **MemoryLeakDetector** - Monitor memory usage and detect potential leaks
- **Benchmark** - Performance benchmarking and load testing utilities

## Profiler

The built-in profiler helps you identify performance bottlenecks by measuring execution time and memory usage of specific code blocks.

### Basic Usage

```crystal
# Enable profiling
Azu::DevelopmentTools.profiler.enabled = true

# Profile a code block
result = Azu::DevelopmentTools.profile("database_query") do
  User.where(active: true).limit(100).to_a
end

# Get profiler statistics
stats = Azu::DevelopmentTools.profiler.stats
puts stats["database_query"]

# Generate a detailed report
puts Azu::DevelopmentTools.profiler.report
```

### Advanced Profiling

```crystal
# Profile with call stack capture
result = Azu::DevelopmentTools.profiler.profile("complex_operation", capture_stack: true) do
  complex_business_logic
end

# Get all profile entries
entries = Azu::DevelopmentTools.profiler.entries
entries.each do |entry|
  puts "#{entry.name}: #{entry.duration.total_milliseconds}ms"
  puts "Memory delta: #{entry.memory_delta_mb}MB"
end

# Clear profiler data
Azu::DevelopmentTools.profiler.clear
```

### Endpoint Profiling

```crystal
struct ProfiledEndpoint
  include Azu::Endpoint(ProfiledRequest, ProfiledResponse)

  get "/profiled/:id"

  def call : ProfiledResponse
    # Profile database operations
    user = Azu::DevelopmentTools.profile("user_lookup") do
      User.find(@request.params["id"].to_i32)
    end

    # Profile template rendering
    content = Azu::DevelopmentTools.profile("template_render") do
      render_user_template(user)
    end

    ProfiledResponse.new(content)
  end
end
```

### Profile Statistics

The profiler tracks comprehensive statistics for each named operation:

```crystal
stats = Azu::DevelopmentTools.profiler.stats
# Returns hash with structure:
# {
#   "operation_name" => {
#     "count" => 25.0,
#     "total_time_ms" => 1250.5,
#     "avg_time_ms" => 50.02,
#     "min_time_ms" => 12.1,
#     "max_time_ms" => 125.7,
#     "total_memory_mb" => 15.2,
#     "avg_memory_mb" => 0.608,
#     "max_memory_mb" => 2.1
#   }
# }
```

## Memory Leak Detector

The memory leak detector monitors your application's memory usage over time and can identify potential memory leaks through pattern analysis.

### Basic Usage

```crystal
# Start memory monitoring (30-second intervals)
detector = Azu::DevelopmentTools.memory_detector
detector.start_monitoring(30.seconds)

# Take manual snapshots
snapshot = detector.take_snapshot
puts "Current heap size: #{snapshot.heap_size / 1024 / 1024}MB"

# Analyze for potential leaks
analysis = detector.analyze_leak
if analysis.leak_detected?
  puts "Memory leak detected!"
  puts "Growth: #{analysis.memory_growth_mb}MB over #{analysis.duration.total_hours}h"
  puts "Suspected issues: #{analysis.suspected_leaks}"
end

# Stop monitoring
detector.stop_monitoring
```

### Memory Analysis

```crystal
# Get recent memory snapshots
recent_snapshots = detector.recent_snapshots(20)

# Analyze memory growth between specific snapshots
start_snapshot = recent_snapshots.first
end_snapshot = recent_snapshots.last
analysis = detector.analyze_leak(start_snapshot, end_snapshot)

puts "Memory growth: #{analysis.memory_growth_mb}MB"
puts "Duration: #{analysis.duration.total_minutes} minutes"
puts "Leak detected: #{analysis.leak_detected?}"
```

### Memory Reporting

```crystal
# Generate comprehensive memory report
puts detector.report

# Example output:
# === Memory Leak Detection Report ===
# Monitoring Period: 2.5 hours
# Memory Growth: 15.3MB
# Leak Detected: YES
#
# Suspected Issues:
# - Large memory growth detected
# - High memory growth with deferred GC - possible leak
#
# Memory Trend (last 10 snapshots):
# 2024-01-15 10:00:00: 45.2MB
# 2024-01-15 10:30:00: 47.8MB
# 2024-01-15 11:00:00: 52.1MB
# ...
```

## Benchmark

The benchmark utility provides tools for measuring code performance and conducting load tests.

### Code Benchmarking

```crystal
# Simple benchmark
result = Azu::DevelopmentTools::Benchmark.run("string_building", 1000) do
  String.build do |str|
    100.times { str << "test" }
  end
end

puts "Average time: #{result.avg_time.total_milliseconds}ms"
puts "Operations per second: #{result.ops_per_second}"
puts "Memory used: #{result.memory_usage} bytes"
```

### Comparative Benchmarking

```crystal
# Compare multiple implementations
benchmarks = {
  "string_concat" => ->{
    str = ""
    100.times { str += "test" }
  },
  "string_build" => ->{
    String.build do |str|
      100.times { str << "test" }
    end
  },
  "array_join" => ->{
    parts = Array(String).new(100, "test")
    parts.join
  }
}

results = Azu::DevelopmentTools::Benchmark.compare(benchmarks, 500)
results.each_with_index do |result, index|
  puts "#{index + 1}. #{result.name}: #{result.avg_time.total_microseconds}μs"
end
```

### Load Testing

```crystal
# Load test an HTTP endpoint
results = Azu::DevelopmentTools::Benchmark.load_test(
  url: "http://localhost:4000/api/users",
  concurrent: 10,          # 10 concurrent connections
  requests: 1000,          # 1000 total requests
  timeout: 30.seconds      # 30-second timeout
)

puts "Results:"
puts "  Total requests: #{results["total_requests"]}"
puts "  Successful: #{results["successful_requests"]}"
puts "  Failed: #{results["failed_requests"]}"
puts "  Requests/sec: #{results["requests_per_second"]}"
puts "  Avg response time: #{results["avg_response_time_ms"]}ms"
puts "  Min response time: #{results["min_response_time_ms"]}ms"
puts "  Max response time: #{results["max_response_time_ms"]}ms"
```

## Development Mode

Enable all development tools with a single call:

```crystal
# Enable all development tools
Azu::DevelopmentTools.enable_development_mode

# This enables:
# - Profiler
# - Memory monitoring (30-second intervals)
# - Enhanced logging

# Disable development mode
Azu::DevelopmentTools.disable_development_mode
```

## Integration Examples

### Application Startup

```crystal
# In your application startup
module MyApp
  include Azu

  configure do |config|
    if config.environment.development?
      # Enable development tools in development
      Azu::DevelopmentTools.enable_development_mode
    end
  end
end
```

### Middleware Integration

```crystal
# Custom profiling middleware
struct ProfilingMiddleware
  include Azu::Handler

  def call(request, response)
    endpoint_name = request.path.gsub("/", "_")

    Azu::DevelopmentTools.profile("endpoint_#{endpoint_name}") do
      @next.call(request, response)
    end
  end
end

# Add to handler chain
MyApp.start [
  ProfilingMiddleware.new,
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]
```

### Background Job Profiling

```crystal
# Profile background job performance
class EmailJob
  def perform(user_id : Int32)
    Azu::DevelopmentTools.profile("email_job") do
      user = Azu::DevelopmentTools.profile("user_fetch") do
        User.find(user_id)
      end

      Azu::DevelopmentTools.profile("email_send") do
        EmailService.send_welcome_email(user)
      end
    end
  end
end
```

### Component Performance

```crystal
class PerformanceAwareComponent
  include Azu::Component

  def refresh
    Azu::DevelopmentTools.profile("component_refresh_#{self.class.name}") do
      super
    end
  end

  def content
    Azu::DevelopmentTools.profile("component_render_#{self.class.name}") do
      super
    end
  end
end
```

## Best Practices

### 1. Enable in Development Only

```crystal
# Only enable profiling in development
if Azu::CONFIG.environment.development?
  Azu::DevelopmentTools.profiler.enabled = true
  Azu::DevelopmentTools.memory_detector.start_monitoring
end
```

### 2. Use Meaningful Names

```crystal
# Good: Descriptive names
Azu::DevelopmentTools.profile("user_authentication") { ... }
Azu::DevelopmentTools.profile("database_user_lookup") { ... }
Azu::DevelopmentTools.profile("password_hash_verification") { ... }

# Bad: Generic names
Azu::DevelopmentTools.profile("operation1") { ... }
Azu::DevelopmentTools.profile("stuff") { ... }
```

### 3. Profile Granularly

```crystal
# Profile at the right level of granularity
def process_user_data(user_id)
  # Too granular - overhead exceeds benefit
  Azu::DevelopmentTools.profile("variable_assignment") do
    user = nil
  end

  # Good granularity - meaningful operations
  user = Azu::DevelopmentTools.profile("user_database_fetch") do
    User.find(user_id)
  end

  result = Azu::DevelopmentTools.profile("user_data_processing") do
    process_complex_user_logic(user)
  end

  result
end
```

### 4. Monitor Memory in Long-Running Processes

```crystal
# For long-running applications
if Azu::CONFIG.environment.production?
  # Monitor memory with longer intervals in production
  Azu::DevelopmentTools.memory_detector.start_monitoring(5.minutes)

  # Set up periodic reporting
  spawn do
    loop do
      sleep 1.hour
      analysis = Azu::DevelopmentTools.memory_detector.analyze_leak
      if analysis.leak_detected?
        Log.warn { "Memory leak detected: #{analysis.memory_growth_mb}MB growth" }
      end
    end
  end
end
```

### 5. Benchmark Before Optimizing

```crystal
# Always benchmark current implementation first
current_result = Azu::DevelopmentTools::Benchmark.run("current_implementation") do
  current_slow_method
end

# Then benchmark optimized version
optimized_result = Azu::DevelopmentTools::Benchmark.run("optimized_implementation") do
  new_fast_method
end

improvement = (current_result.avg_time - optimized_result.avg_time) / current_result.avg_time
puts "Performance improvement: #{(improvement * 100).round(2)}%"
```

## API Endpoints

Create endpoints to access development tools data:

```crystal
# Development tools status endpoint
struct DevToolsStatusEndpoint
  include Azu::Endpoint(Azu::Request::Empty, JsonResponse)

  get "/admin/dev-tools/status"

  def call : JsonResponse
    profiler = Azu::DevelopmentTools.profiler
    detector = Azu::DevelopmentTools.memory_detector

    JsonResponse.new({
      "profiler" => {
        "enabled" => profiler.enabled,
        "entries_count" => profiler.entries.size,
        "stats" => profiler.stats
      },
      "memory_detector" => {
        "monitoring" => detector.monitoring?,
        "snapshots_count" => detector.recent_snapshots.size,
        "latest_analysis" => detector.analyze_leak
      }
    })
  end
end

# Performance report endpoint
struct DevToolsReportEndpoint
  include Azu::Endpoint(Azu::Request::Empty, TextResponse)

  get "/admin/dev-tools/report"

  def call : TextResponse
    report = String.build do |str|
      str << "=== Development Tools Report ===\n\n"
      str << Azu::DevelopmentTools.profiler.report
      str << "\n\n"
      str << Azu::DevelopmentTools.memory_detector.report
    end

    TextResponse.new(report)
  end
end
```

## Performance Impact

The development tools are designed with minimal performance overhead:

- **Profiler**: ~0.1-0.5ms overhead per profiled operation
- **Memory Detector**: ~1-2ms per snapshot (taken at intervals)
- **Benchmarking**: No runtime overhead (used for testing only)

## Troubleshooting

### Common Issues

1. **Profiler Not Capturing Data**

   ```crystal
   # Ensure profiler is enabled
   puts "Profiler enabled: #{Azu::DevelopmentTools.profiler.enabled}"
   Azu::DevelopmentTools.profiler.enabled = true
   ```

2. **Memory Monitoring Not Starting**

   ```crystal
   # Check if already monitoring
   detector = Azu::DevelopmentTools.memory_detector
   puts "Already monitoring: #{detector.monitoring?}"
   ```

3. **Load Test Connection Errors**
   ```crystal
   # Use appropriate timeout and handle network issues
   results = Azu::DevelopmentTools::Benchmark.load_test(
     url: "http://localhost:4000/health",
     concurrent: 5,     # Start with lower concurrency
     requests: 100,     # Start with fewer requests
     timeout: 60.seconds # Increase timeout
   )
   ```

## Conclusion

Azu's development tools provide comprehensive insights into your application's performance characteristics. Use the profiler to identify bottlenecks, the memory leak detector to ensure memory efficiency, and the benchmark utilities to validate optimizations. These tools are essential for maintaining high-performance Azu applications in both development and production environments.

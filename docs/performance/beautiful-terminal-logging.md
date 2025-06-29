# Beautiful Terminal Performance Logging

Azu provides stunning, colorful performance reports that make monitoring your application's performance a visual delight. The beautiful terminal logging system transforms raw metrics into eye-catching, informative displays.

## ✨ Features Overview

### 🎨 Beautiful Report Formatting

- **Colorized output** with semantic colors (green=good, yellow=warning, red=error)
- **Unicode box drawing** characters for professional layouts
- **Emoji indicators** for different metrics and sections
- **Visual progress bars** for memory usage, response times, and error rates
- **Responsive layouts** that adapt to terminal width

### 📊 Multiple Report Types

- **Full Detailed Report** - Comprehensive performance analysis
- **Compact Summary** - One-line performance overview
- **Health Check** - Current system status
- **Time-based Reports** - Hourly and daily performance summaries

## 🚀 Quick Start

### Basic Usage

```crystal
# Log a beautiful performance report
Azu::PerformanceReporter.log_beautiful_report

# Log a compact summary
Azu::PerformanceReporter.log_summary

# Check current system health
Azu::PerformanceReporter.log_health_check
```

### Integration in Your App

```crystal
module MyApp
  include Azu

  configure do |config|
    config.performance_enabled = true
  end
end

MyApp.start [
  Azu::Handler::PerformanceMonitor.new,  # Enable automatic tracking
  Azu::Handler::Rescuer.new,
  Azu::Handler::Logger.new,
]

# Optional: Start periodic reporting in development
Azu::PerformanceReporter.start_periodic_reporting(5.minutes)
```

## 📋 Report Types

### 1. Full Beautiful Report

The crown jewel of performance reporting - a comprehensive, beautifully formatted display:

```crystal
Azu::PerformanceReporter.log_beautiful_report
```

**Sample Output:**

```shell
 AZU   Sun 06/29/2025 10:16:10 ⤑   Info  ⤑  Example_app ⤑  127.0.0.1 ⤑ GET Path: /demo/reporting/full Endpoint: DemoReportingEndpoint Status: 200 Latency: 630.29µs

🌈 Full Performance Report:

╔══════════════════════════════════════════════════════════════════════════════╗
                           🚀 PERFORMANCE REPORT 🚀

📊 Analysis Period: 14:15:50 → 14:16:18
   Duration: 28.4s

┌─ REQUEST METRICS ──────────────────────────────────────────────────
  📈 Total Requests: 6 █░░░░░░░░░░░░░░░░░░░
  ❌ Error Rate: 0.0% (0/6) ░░░░░░░░░░░░░░░░░░░░

┌─ RESPONSE TIME METRICS ──────────────────────────────────────────
  ⏱️  Average: 1669.19ms ████████████████████
  🏃 Fastest: 0.26ms   🐌 Slowest: 5006.17ms
  📊 95th %ile: 5005.47ms   99th %ile: 5005.47ms

┌─ MEMORY METRICS ────────────────────────────────────────────────
  🧠 Average Usage: 0.0MB ░░░░░░░░░░░░░░░░░░░░
  📈 Peak Usage: 0.0MB ░░░░░░░░░░░░░░░░░░░░
  💾 Total Allocated: 0.0MB

┌─ TOP ENDPOINTS ─────────────────────────────────────────────────
  1. CachedEndpoint              2 reqs
     ⏱️ 5005.8ms  ❌ 0.0%
  2. HtmlEndpoint                2 reqs
     ⏱️ 1.3ms  ❌ 0.0%
  3. DemoReportingEndpoint       1 reqs
     ⏱️ 0.7ms  ❌ 0.0%
  4. JsonEndpoint                1 reqs
     ⏱️ 0.3ms  ❌ 0.0%

Generated at 10:16:18 | Monitoring: ENABLED ✓
```

### 2. Compact Summary

Perfect for quick health checks or logging at the end of operations:

```crystal
Azu::PerformanceReporter.log_summary
```

**Sample Output:**

```
🚀 PERFORMANCE SUMMARY | 1.2K reqs | 85.3ms avg | 2.1% errors | 2.4MB mem
```

### 3. Health Check

Monitor current system status with real-time metrics:

```crystal
Azu::PerformanceReporter.log_health_check
```

**Sample Output:**

```
💚 SYSTEM HEALTH CHECK
Current Memory: 15.4MB | Monitoring: ACTIVE ✓
Recent Activity: 1200 requests | Avg: 85.3ms | Errors: 2.1%
```

### 4. Time-based Reports

Get performance summaries for specific time periods:

```crystal
# Last hour performance
Azu::PerformanceReporter.log_hourly_report

# Last 24 hours performance
Azu::PerformanceReporter.log_daily_report

# Custom time range
Azu::PerformanceReporter.log_beautiful_report(1.hour.ago)
```

## 🎛️ Advanced Features

### Periodic Reporting

Automatically log performance reports at regular intervals:

```crystal
# Every 5 minutes (development only)
Azu::PerformanceReporter.start_periodic_reporting(5.minutes)

# Every 30 seconds with compact summary
Azu::PerformanceReporter.start_periodic_reporting(30.seconds, beautiful: false)
```

### Signal Handling for Live Debugging

Add signal handlers for on-demand reporting:

```crystal
# Send SIGUSR1 to process for beautiful report
Signal::USR1.trap do
  Azu::PerformanceReporter.log_beautiful_report
end

# Send SIGUSR2 for health check
Signal::USR2.trap do
  Azu::PerformanceReporter.log_health_check
end
```

### HTTP Endpoints for Remote Monitoring

Access reports via HTTP endpoints (useful for monitoring dashboards):

```crystal
# Add to your routes
struct PerformanceReportEndpoint
  include Azu::Endpoint(EmptyRequest, GenericJsonResponse)

  get "/admin/performance/report"

  def call : GenericJsonResponse
    # This logs the beautiful report to server terminal
    Azu::PerformanceReporter.log_beautiful_report

    GenericJsonResponse.new({
      "message" => "Performance report logged to server terminal",
      "timestamp" => Time.utc.to_rfc3339
    })
  end
end
```

**Available endpoints in example app:**

- `GET /performance/report` - Logs beautiful report to terminal
- `GET /demo/reporting/full` - Full detailed report
- `GET /demo/reporting/summary` - Compact summary
- `GET /demo/reporting/health` - Health check
- `GET /demo/reporting/help` - Show available commands

## 🎨 Color Coding System

The beautiful reports use semantic colors to convey meaning at a glance:

### Response Times

- 🟢 **Green (0-50ms)** - Excellent performance
- 🟡 **Light Green (50-200ms)** - Good performance
- 🟠 **Yellow (200-500ms)** - Acceptable performance
- 🔴 **Light Red (500-1000ms)** - Slow performance
- ⚫ **Red (1000ms+)** - Poor performance

### Error Rates

- 🟢 **Green (0-1%)** - Healthy error rate
- 🟡 **Yellow (1-5%)** - Elevated error rate
- 🔴 **Red (5%+)** - High error rate

### Memory Usage

- 🟢 **Green (0-1MB)** - Low usage
- 🟡 **Light Green (1-5MB)** - Normal usage
- 🟠 **Yellow (5-20MB)** - Moderate usage
- 🔴 **Light Red (20-50MB)** - High usage
- ⚫ **Red (50MB+)** - Very high usage

## 🔧 Configuration

### Environment Variables

```bash
# Enable performance monitoring (default: true)
PERFORMANCE_MONITORING=true

# Set thresholds for warnings
PERFORMANCE_SLOW_REQUEST_THRESHOLD=1000  # milliseconds
PERFORMANCE_MEMORY_THRESHOLD=10485760    # bytes (10MB)
```

### Programmatic Configuration

```crystal
# Enable/disable monitoring
Azu::PerformanceReporter.enable_monitoring!
Azu::PerformanceReporter.disable_monitoring!

# Clear all metrics
Azu::PerformanceReporter.clear_metrics!
```

## 📱 Usage Examples

### During Development

```crystal
# At application startup
puts "Starting MyApp with performance monitoring..."
Azu::PerformanceReporter.log_health_check

# After running tests
puts "\nTest suite completed!"
Azu::PerformanceReporter.log_summary

# During debugging sessions
Azu::PerformanceReporter.log_beautiful_report
```

### In Production Scripts

```crystal
# Daily maintenance script
puts "Daily maintenance starting..."
Azu::PerformanceReporter.log_daily_report

# Performance optimization analysis
puts "Analyzing yesterday's performance..."
yesterday = Time.utc - 1.day
Azu::PerformanceReporter.log_beautiful_report(yesterday)
```

### API Monitoring

```crystal
# In a monitoring endpoint
get "/admin/status" do
  Azu::PerformanceReporter.log_health_check
  # Return JSON response
end
```

## 🎭 Demo Script

Try the included demo script to see all features in action:

```bash
crystal run playground/demo_beautiful_reporting.cr
```

This demo creates sample performance data and showcases all the beautiful reporting features with realistic metrics.

## 🚀 Best Practices

### When to Use Each Report Type

1. **Full Beautiful Report**

   - End of day/week summaries
   - Performance analysis sessions
   - Debugging performance issues
   - Weekly team reviews

2. **Compact Summary**

   - Application startup/shutdown
   - End of test runs
   - Quick health checks
   - Continuous monitoring scripts

3. **Health Check**
   - Live monitoring dashboards
   - Automated health checks
   - Load balancer health endpoints
   - Real-time system status

### Terminal Compatibility

The beautiful reports work best with:

- **Modern terminals** that support Unicode and 256 colors
- **Terminal width** of at least 80 characters
- **Color support** enabled in your terminal

For systems without color support, the reports gracefully degrade to plain text while maintaining readability.

## 🔍 Troubleshooting

### Reports Not Showing Colors

```crystal
# Check if colors are enabled
puts "Colors enabled: #{STDOUT.tty?}"

# Force color output (if needed)
ENV["FORCE_COLOR"] = "true"
```

### Performance Impact

The beautiful reporting system is designed for minimal overhead:

- **Report generation**: ~1-5ms depending on data size
- **Memory usage**: Minimal, reports are generated on-demand
- **Production impact**: Negligible when used appropriately

### Common Issues

1. **Terminal width too narrow**: Reports adapt but may wrap oddly
2. **Unicode not supported**: Install fonts with Unicode support
3. **Colors not showing**: Check terminal color support settings

## 🎉 Conclusion

The beautiful terminal performance logging transforms mundane performance monitoring into an engaging, visual experience. Whether you're debugging issues, monitoring production systems, or just want to keep an eye on your application's health, these colorful, informative reports make performance data accessible and actionable.

The combination of semantic colors, visual progress bars, and well-organized layouts ensures that critical performance information is immediately apparent, helping you build faster, more reliable applications.

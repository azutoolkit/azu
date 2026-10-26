---
description: Record request, cache and component metrics with the performance monitor, and read them from code or as a report.
---

# Monitor performance in development

{% hint style="warning" %}
This is development tooling, not production monitoring: the numbers live in the memory of one process.
{% endhint %}

{% stepper %}
{% step %}
#### Load `azu/dev`

The performance monitor is not part of `require "azu"`:

```crystal
require "azu"
require "azu/dev"
```
{% endstep %}

{% step %}
#### Switch monitoring on

```bash
export PERFORMANCE_MONITORING=true
```

Until then `config.performance_monitor` is `nil` and nothing is recorded. The profiler, the memory monitor and the
warning thresholds have variables of their own: see
[Configuration options](../../reference/configuration/options.md#environment-variables).
{% endstep %}

{% step %}
#### Put the monitor in the handler chain

```crystal
require "azu"
require "azu/dev"

module MyApp
  include Azu
end

handlers = Azu::App.default.default_handlers
if monitor = MyApp.config.performance_monitor # nil unless PERFORMANCE_MONITORING=true
  handlers.unshift monitor
end

MyApp.start handlers
```

Use `config.performance_monitor`, not a `Handler::PerformanceMonitor.new` of your own: it is the one instance the
dashboard and the reporters read. In front of the default stack it times every handler.
{% endstep %}
{% endstepper %}

Every request through the monitor is recorded with its endpoint, status, duration and heap growth, and so are cache
operations and live component events. A request slower than `PERFORMANCE_SLOW_REQUEST_THRESHOLD` milliseconds (1000
by default) is logged as a warning. With `PERFORMANCE_SLOW_REQUEST_THRESHOLD=20` and an endpoint that takes 30 ms:

```text
2026-10-26T15:14:55.750326Z   WARN - Azu: Slow request detected: ReportEndpoint took 30.214463ms
```

## Read the numbers

In the browser, mount the dashboard next to the monitor: see [Use the dev dashboard](use-dev-dashboard.md).

From code:

```crystal
require "azu"
require "azu/dev"

if monitor = Azu::CONFIG.performance_monitor
  stats = monitor.stats
  puts "Requests: #{stats.total_requests}, p95: #{stats.p95_response_time.round(1)}ms, errors: #{stats.error_rate}%"
  monitor.endpoint_stats("ReportEndpoint")["avg_response_time"]? # per endpoint
end
```

As a report, on demand or, in development, every minute:

```crystal
require "azu"
require "azu/dev"

reports = Azu::PerformanceReportService.new
reports.log_summary                        # one line on standard output
json = reports.generate_json_report        # requests, latency, error rate and cache figures as JSON
reports.start_periodic_reporting(:log, 60.seconds)
```

The methods, the fields of the stats and the JSON keys are listed in [Dev tools](../../reference/dev/azu-dev.md).

## See also

- [Use the dev dashboard](use-dev-dashboard.md)
- [Dev tools](../../reference/dev/azu-dev.md)
- [Performance design](../../explanation/architecture/performance-design.md)

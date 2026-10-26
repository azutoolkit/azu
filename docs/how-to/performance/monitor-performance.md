# Monitor performance in development

You will turn on request, cache and component metrics and read them in the dev dashboard. This is development tooling, not production monitoring.

The dashboard, the performance monitor, the profiler and the memory leak detector are not part of `require "azu"`. Add them with one line; an app that does not need them does not load them.

```crystal
require "azu"
require "azu/dev" # Handler::DevDashboard, Handler::PerformanceMonitor, PerformanceMetrics, DevelopmentTools, ...
```

## Switch metrics on

With `azu/dev` loaded nothing is recorded until monitoring is on:

```bash
export PERFORMANCE_MONITORING=true

# Optional: profiler and memory monitor (on by default in development, off elsewhere)
export PERFORMANCE_PROFILING=true
export PERFORMANCE_MEMORY_MONITORING=true
```

Building with `PERFORMANCE_MONITORING=true` or `--define=performance_monitoring` also makes `require "azu"` load `azu/dev`, for apps that always did that.

## Add the handlers

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
handlers.unshift Azu::Handler::DevDashboard.new if MyApp.env.development?

MyApp.start handlers
```

`default_handlers` is the stack `start` uses on its own (request id, logging, error pages, security headers, static files); the monitor and the dashboard go in front of it. Put the shared monitor from `config.performance_monitor` in the chain: the dashboard and the code below read that instance, so a `Handler::PerformanceMonitor.new` of your own would record numbers that neither of them shows. `DevDashboard` serves only when the environment is development, whatever the list says. Open `/dev-dashboard`.

## What you get

- Request metrics: response times, memory use, error rates.
- Component and cache metrics: mount and refresh timings, hit rates.
- Memory monitoring: leak detection and profiling.
- With `azu/cql`: every query tied to its request, slow statements and N+1 patterns ([Database dashboard](../../reference/database-dashboard.md)).

Core only calls `Azu::Instrumentation`, a nil check when nobody listens, so without `azu/dev` no dashboard, monitor, profiler or reporter code is compiled and no metrics are collected.

## Read the numbers from code

```crystal
require "azu"
require "azu/dev"

if monitor = Azu::CONFIG.performance_monitor
  stats = monitor.stats
  puts "Average response time: #{stats.avg_response_time}ms"
  puts "Error rate: #{stats.error_rate}%"
end
```

See [Performance design](../../explanation/architecture/performance-design.md) for what the framework itself costs.

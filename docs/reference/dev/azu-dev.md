---
description: "What `require \"azu/dev\"` adds: the dev dashboard and performance monitor handlers, the metrics they share, the reporters, and the profiler, memory leak detector and benchmark helpers."
---

# Dev tools

`require "azu/dev"`, after `require "azu"`, loads Azu's development tooling: `Handler::DevDashboard`,
`Handler::PerformanceMonitor`, the `PerformanceMetrics` store they share, the reporters, and `DevelopmentTools`
(profiler, memory leak detector, benchmarks). `require "azu"` alone loads none of it: core reports cache and component
events through `Azu::Instrumentation`, which costs a nil check while nothing subscribes. Compiling with
`PERFORMANCE_MONITORING=true` in the compiler's environment, or with `-Dperformance_monitoring`, makes `require "azu"`
load `azu/dev` as well. This is development tooling, not production monitoring: the numbers live in the memory of one
process, and the dashboard serves in development only.

```crystal
require "azu"
require "azu/dev"

module MyApp
  include Azu

  configure do |config|
    config.performance_enabled = true # what PERFORMANCE_MONITORING=true sets
  end
end

monitor = MyApp.config.performance_monitor.not_nil! # the one shared monitor
dashboard = Azu::Handler::DevDashboard.new           # shows monitor.metrics
dashboard.metrics.same?(monitor.metrics)             # => true
```

[Use the dev dashboard](../../how-to/performance/use-dev-dashboard.md) puts both in an app's handler chain.

## API

### `Handler::DevDashboard`

`Azu::Handler::DevDashboard.new(path = "/dev-dashboard", metrics = nil, log = Azu::CONFIG.log, queries = QueryStore.instance)`

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `path` | `String` | `"/dev-dashboard"` (`DEFAULT_PATH`) | Where the page is served; the SQL playground is at `{path}/sql` |
| `metrics` | `PerformanceMetrics?` | the metrics of `Azu::CONFIG.performance_monitor`, else a new empty store | The request, cache and component numbers the page shows. Read once, when the handler is built |
| `log` | `::Log` | `Azu::CONFIG.log` | Receives rendering errors and the "metrics cleared" line |
| `queries` | `QueryStore` | `QueryStore.instance` | The store `?clear=true` empties and whose `adapter` the SQL playground uses. The Database tab itself always reads `QueryStore.instance` |

`path`, `metrics`, `queries` and `log` are getters. While it serves, the handler answers:

| Request | Answer |
| --- | --- |
| `{path}`, any method | `200`, `text/html; charset=utf-8`: the whole dashboard as one document (inline CSS, script and icons; it loads nothing from elsewhere) |
| `GET {path}?clear=true` | Clears `metrics` and `queries`, then `302` with `Location: {path}` and an empty body |
| `{path}/sql` | The SQL playground: see [Database dashboard](../database-dashboard.md#sql-playground) |
| Any other path | Passed to the next handler |

An exception while rendering is logged and answered with `500`, `text/plain`, `Dashboard Error: <message>`.

### `Handler::PerformanceMonitor`

`Azu::Handler::PerformanceMonitor.new(metrics = PerformanceMetrics.new, log = Azu::CONFIG.log)`

For every request that passes through it, while `metrics.enabled` is true, it records into `metrics` the method, the
path with its query string, the status, the time from entering the handler to leaving it, and the GC heap size before
and after. The endpoint name is the `X-Azu-Endpoint` request header the router sets (`PingEndpoint`); a request no
endpoint served gets a name built from its path (`/assets/app.css` is `assets_app.css`, `/` is `root`). The request
id is the `X-Request-ID` request header; without one the monitor sets a new one on the request, which
`Handler::RequestId` then keeps.

| Method | Returns | Notes |
| --- | --- | --- |
| `stats(since : Time? = nil)` | `PerformanceMetrics::AggregatedStats` | `metrics.aggregate_stats(since)` |
| `endpoint_stats(endpoint : String, since : Time? = nil)` | `Hash(String, Float64)` | `total_requests`, `error_requests`, `error_rate`, `avg_response_time`, `min_response_time`, `max_response_time`, `p95_response_time`, `p99_response_time`, `avg_memory_usage_mb` |
| `recent_requests(limit = 50)` | `Array(PerformanceMetrics::RequestMetric)` | Oldest first |
| `enabled?`, `enabled=(value : Bool)` | `Bool` | Turns recording on and off (on when built) |
| `clear_metrics` | `Nil` | Empties `metrics` |
| `generate_report(since : Time? = nil)` | `String` | Plain text, starting with `=== Performance Report ===` |
| `log_summary_report(since = nil)`, `log_beautiful_report(since = nil)` | `Nil` | Coloured reports written to standard output |
| `to_json(io : IO)` | `Nil` | `stats`, the last 50 requests, components and cache operations, `cache_stats`, `cache_breakdown`, `endpoint_breakdown` |

### `PerformanceMetrics`

`Azu::PerformanceMetrics.new(enabled = true)` is the in-memory store behind the monitor and the dashboard. All
instances share one lock, so recording from many fibers is safe.

| Method | Returns | Notes |
| --- | --- | --- |
| `aggregate_stats(since : Time? = nil)` | `AggregatedStats` | Over the requests recorded at or after `since`, by default since the store was built or last cleared (`start_time`) |
| `endpoint_stats(endpoint, since = nil)` | `Hash(String, Float64)` | As on the monitor |
| `cache_stats(store_type = nil, since = nil)` | `Hash(String, Float64)` | `total_operations`, `get_operations`, `set_operations`, `delete_operations`, `error_operations`, `hit_operations`, `miss_operations`, `hit_rate`, `error_rate`, `avg_processing_time`, `min_processing_time`, `max_processing_time`, `avg_value_size_bytes`, `total_data_written` |
| `cache_operation_breakdown(since = nil)` | `Hash(String, Hash(String, Float64))` | The same figures per operation |
| `component_stats(component_type = nil, since = nil)` | `Hash(String, Float64)` | Mount, refresh and event timings of live components |
| `recent_requests(limit = 100)`, `recent_caches(limit = 100)`, `recent_components(limit = 100)` | arrays of `RequestMetric`, `CacheMetric`, `ComponentMetric` | Oldest first |
| `record_request(...)`, `record_cache(...)`, `record_component(...)` | `Nil` | What the monitor and the instrumentation hooks call; nothing is recorded while `enabled` is false |
| `clear` | `Nil` | Empties the store and resets `start_time` |
| `PerformanceMetrics.current_memory_usage` | `Int64` | `GC.stats.heap_size`, in bytes |

`AggregatedStats` has `total_requests`, `error_requests` (status 400 or above), `error_rate` (a percentage, two
decimals), `avg_response_time`, `min_response_time`, `max_response_time`, `p95_response_time`, `p99_response_time`
(milliseconds), `avg_memory_usage` and `peak_memory_usage` (heap growth per request, in MB), `total_memory_allocated`
(bytes), `start_time` and `end_time`.

### Reporters

Every reporter reads `Azu::CONFIG.performance_monitor`, the monitor of the global configuration. While it is `nil` a
report is the message `Performance monitoring is not enabled` (`{"error":"Performance monitoring is not enabled"}` in
JSON).

| Type | Methods |
| --- | --- |
| `LogPerformanceReporter` | `output_report(since = nil)`, `log_summary(since = nil)`, `log_health_check`, `log_hourly_report`, `log_daily_report`: coloured text on standard output |
| `JsonPerformanceReporter` | `generate_report(since = nil)`, `generate_health_check`, `generate_hourly_report`, `generate_daily_report`: a JSON `String` |
| `PerformanceReportService` | The methods of both under one object (`log_beautiful_report`, `log_summary`, `log_health_check`, `log_hourly_report`, `log_daily_report`, `generate_json_report`, `generate_json_health_check`, `generate_json_hourly_report`, `generate_json_daily_report`), plus `start_periodic_reporting(format = :log, interval = 60.seconds)` (`:json` for JSON) and `show_help` |
| `PerformanceReportScheduler` | `start_periodic_reporting(reporter, interval = 60.seconds)`: a fiber that prints `reporter.output_report` every `interval` |
| `PerformanceMonitoringManager` | `enable!`, `disable!`, `clear_metrics!`: switch or clear the shared monitor and print a line; `enabled?` |

The hourly and daily reports cover the last hour and the last day. A JSON report has the keys `timestamp`, `since`,
`performance` (`total_requests`, `avg_response_time_ms`, `error_rate_percent`, `requests_per_second`,
`memory_usage_mb`), `cache` and `monitoring`; a JSON health check has `status`, `timestamp`, `memory_usage_mb`,
`monitoring_enabled` and `recent_activity`.

### `DevelopmentTools`

| Member | Returns | Notes |
| --- | --- | --- |
| `DevelopmentTools.profiler` | `Profiler` | One per process |
| `DevelopmentTools.memory_detector` | `MemoryLeakDetector` | One per process |
| `DevelopmentTools.profile(name) { ... }` | the block's value | `profiler.profile(name) { ... }` |
| `DevelopmentTools.enable_development_mode`, `disable_development_mode` | `Nil` | The first turns the profiler on and starts memory monitoring; the second undoes both |

**`Profiler`** (`Profiler.new(enabled = false)`):

| Method | Returns | Notes |
| --- | --- | --- |
| `profile(name, capture_stack = false) { ... }` | the block's value | While `enabled`, records the block's duration and the heap size before and after; otherwise only runs the block |
| `enabled`, `enabled=(value : Bool)` | `Bool` | |
| `entries` | `Array(Profiler::ProfileEntry)` | The last 10,000 |
| `stats` | `Hash(String, Hash(String, Float64))` | Per name: `count`, `total_time_ms`, `avg_time_ms`, `min_time_ms`, `max_time_ms`, `total_memory_mb`, `avg_memory_mb`, `max_memory_mb` |
| `report` | `String` | Starts with `=== Profiler Report ===` |
| `clear` | `Nil` | |

The dashboard's Performance Tracing tab lists the ten names with the most total time.

**`MemoryLeakDetector`**:

| Method | Returns | Notes |
| --- | --- | --- |
| `start_monitoring(interval = 30.seconds)`, `stop_monitoring` | `Nil` | A fiber that takes a snapshot every `interval` |
| `take_snapshot` | `MemorySnapshot` | `timestamp`, `heap_size`, `gc_stats` (`heap_size`, `free_bytes`, `unmapped_bytes`, `bytes_since_gc`, `total_bytes`); the last 1,000 are kept |
| `analyze_leak(start_snapshot = nil, end_snapshot = nil)` | `LeakAnalysis` | Between the first and the last snapshot by default; raises `Exception` (`Not enough snapshots for analysis`) when there is none |
| `recent_snapshots(limit = 100)` | `Array(MemorySnapshot)` | |
| `report` | `String` | `No memory snapshots available` before the first snapshot |

`LeakAnalysis` has `memory_growth` (bytes), `memory_growth_mb`, `duration`, `suspected_leaks` and `leak_detected?`, which
is true when the heap grew by more than 10 MB. `suspected_leaks` names growth over 50 MB, and growth over 10 MB with more
than 50 MB allocated since the last collection.

**`Benchmark`**:

| Method | Returns | Notes |
| --- | --- | --- |
| `Benchmark.run(name, iterations = 1000, warmup = 100) { ... }` | `BenchmarkResult` | Runs the block `warmup` times, collects garbage, then times `iterations` runs |
| `Benchmark.compare(benchmarks : Hash(String, Proc(Nil)), iterations = 1000)` | `Array(BenchmarkResult)` | Fastest first |
| `Benchmark.load_test(url, concurrent = 10, requests = 1000, timeout = 30.seconds)` | `Hash(String, Float64)` | `requests` GETs over `concurrent` fibers: `total_requests`, `successful_requests`, `failed_requests` (any non-2xx or error), `requests_per_second`, `avg_`/`min_`/`max_response_time_ms` (successes only, `0.0` without one), `total_time_seconds`. Answers that come more than `timeout` after the start are not counted; the workers still finish their requests |

`BenchmarkResult` has `name`, `iterations`, `total_time`, `avg_time`, `min_time`, `max_time`, `std_deviation`
(nanoseconds), `memory_usage` (heap growth in bytes), `timestamp` and `ops_per_second`.

## Options

`azu/dev` adds these to `Azu::Configuration`:

| Option | Type | Default | Environment |
| --- | --- | --- | --- |
| `performance_enabled?` | `Bool` | `false` | `PERFORMANCE_MONITORING` (`true` turns it on) |
| `performance_monitor` | `Handler::PerformanceMonitor?` | built on the first call while `performance_enabled?` is true, `nil` otherwise | |
| `performance_profiling_enabled?` | `Bool` | `true` in development, `false` elsewhere | `PERFORMANCE_PROFILING` |
| `performance_memory_monitoring?` | `Bool` | `true` in development, `false` elsewhere | `PERFORMANCE_MEMORY_MONITORING` |
| `development_tools` | `DevelopmentTools` | | |

`performance_enabled=` and `performance_monitor=` set the first two from code. The monitor's slow-request and memory
warnings follow `PERFORMANCE_SLOW_REQUEST_THRESHOLD` and `PERFORMANCE_MEMORY_THRESHOLD`; their defaults are in
[Configuration options](../configuration/options.md#environment-variables).

## Behavior

- **One shared monitor.** `config.performance_monitor` builds one `Handler::PerformanceMonitor` and returns it on every
  later call. The dashboard (built with no `metrics:`), the reporters and the cache and component hooks all use it, so it
  is the instance to put in the handler chain. A `Handler::PerformanceMonitor.new` of your own records into its own
  store, which none of them shows unless you pass it: `DevDashboard.new(metrics: monitor.metrics)`. An app built with
  `Azu::App.new` has a configuration of its own, so its dashboard needs `metrics:`.
- **Cache and component metrics.** With `azu/dev` loaded, every cache operation and live component event is recorded
  into the metrics of `performance_monitor` of the current configuration (`Azu.current_config`: the configuration of the
  app serving the request), while its `performance_enabled?` is true.
- **At start.** `App#prepare`, which `start` calls, turns the profiler on when `performance_profiling_enabled?` and starts
  memory monitoring (a snapshot every 30 seconds) when `performance_memory_monitoring?`.
- **Environment.** `Handler::DevDashboard` serves only while the configuration of the app serving the request is in
  development; elsewhere it passes every request on, and building one logs a warning. See
  [Environments](../configuration/environments.md#what-depends-on-the-environment).
- **Request data.** The dashboard's request panels read the metrics of `Azu::CONFIG.performance_monitor` (or the
  `metrics:` you pass), which exists only with `PERFORMANCE_MONITORING=true`, and that monitor must be in the handler
  chain. Without one, building the dashboard in development logs a warning and its request panels stay empty.
- **Access.** The page has no login of its own. In development Azu binds `127.0.0.1` unless `HOST` or `config.host`
  says otherwise; `start` logs a warning when `CRYSTAL_ENV` is unset and the server listens on another address.
- **CSRF.** Building the dashboard adds `{path}/sql` to `Handler::CSRF.exempt`, in every environment (see
  [App](../api/app.md#limits)).
- **Periodic reports** run only when `Azu::CONFIG.env` is development; elsewhere `start_periodic_reporting` does nothing.

## Limits

- The numbers are per process and in memory: a restart loses them, and several processes each keep their own.
  `PerformanceMetrics` keeps the last 10,000 requests, cache operations and component events, and the last 1,000
  timings per endpoint.
- The memory figures of requests, profiles and benchmarks are GC heap sizes, so a request's heap growth includes what
  other fibers allocated meanwhile.
- `Profiler#profile(name, capture_stack: true)` stores the placeholder `<call_stack_capture_not_implemented>`, not a
  stack.
- The reporters and `PerformanceMonitoringManager` read `Azu::CONFIG`, never the configuration of an `Azu::App.new` app.
- A periodic report cannot be stopped once started.

## See also

- [Use the dev dashboard](../../how-to/performance/use-dev-dashboard.md)
- [Monitor performance in development](../../how-to/performance/monitor-performance.md)
- [Database dashboard](../database-dashboard.md)
- [Performance design](../../explanation/architecture/performance-design.md)

## Shared terminal dashboard

`Azu::Dev::DashboardSnapshot` owns the calculations used by the browser provider and the CLI's optional `dashboard` telemetry field. `Azu::Components::DashboardDataProvider` remains a compatibility façade. The snapshot includes health insights, p50/p99 latency, route counts, cache/component metrics, tracing summaries, profiler spans, and bounded graph series. Its memory series measures GC heap; RSS is a separate value.

`azu dev` supplies a private `AZU_TELEMETRY_SOCKET`. Export runs only in development, once a second, with a write deadline and a 1 MiB payload ceiling. Existing telemetry v1 fields are retained. Use `Azu::CQL.attach { AppDB }` to supply SQL, pool, transaction, and declared-schema metadata without adding a second CQL subscriber.

Optional application integrations can report metadata through:

```crystal
require "azu"
require "azu/dev"

Azu::Dev::IntegrationEvents.sessions("cookie")
Azu::Dev::IntegrationEvents.session("sign-in", "accepted")
Azu::Dev::IntegrationEvents.mailer("WelcomeMailer", "Static example text")
Azu::Dev::IntegrationEvents.delivery("WelcomeMailer", "delivered")
```

These APIs do nothing outside development. Record outcomes only after they are known. Cookie sessions never expose an active-session count; server-side integrations may supply an authoritative `active: count.to_i64`. Mailer previews must be static examples, not customer messages. Events retain at most 100 entries per integration and do not accept credentials, recipients, or session contents.

The CLI labels older or missing telemetry as unavailable, marks stale samples, and hides explicitly disabled features. Production SSH monitoring keeps its separate, sanitized read-only contract.

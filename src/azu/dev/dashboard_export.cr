require "./dashboard_snapshot"
require "./integration_events"

module Azu::Dev
  class DashboardSnapshot
    # Bounded, presentation-neutral data. No SQL parameters, cache keys or session
    # credentials leave the application. Both frontends use this provider's rules.
    def telemetry(config : Configuration)
      cache = cache_stats
      components = component_stats
      database = database_stats
      rt = runtime
      lat = latency
      extensions = IntegrationEvents.snapshot
      {
        sessions: extensions[:sessions],
        mailers:  extensions[:mailers],
        process:  {name: ENV["AZU_APP_NAME"]?.try(&.[0, 256]), pid: rt.pid, port: config.port, started_at: start_time.to_rfc3339,
                  uptime_seconds: uptime.total_seconds, crystal: rt.crystal, environment: rt.environment,
                  rss_bytes: rss_bytes, heap_bytes: rt.heap},
        features: {sessions: extensions[:sessions][:backend] ? "enabled" : "unavailable",
                   mailers: extensions[:mailers][:registered].empty? ? "unavailable" : "enabled",
                   requests: config.performance_enabled? ? "enabled" : "disabled",
                   cache: config.cache_config.enabled? ? "enabled" : "disabled",
                   database: database.active ? "enabled" : "unavailable",
                   components: config.performance_enabled? ? "enabled" : "unavailable",
                   profiler: config.performance_profiling_enabled? ? "enabled" : "disabled"},
        health:   {score: health_score, insights: insights.map { |i| {status: i.status.to_s, message: i.message, detail: i.detail, section: i.tab} }},
        requests: {total: stats.total_requests, failed: stats.error_requests, error_rate: stats.error_rate,
                   rps: requests_per_second, p50_ms: lat.try(&.p50), p95_ms: lat.try(&.p95), p99_ms: lat.try(&.p99),
                   recent_errors: recent_errors.first(10).map { |request| {method: request.method, path: Env.redact_url(request.path)[0, 512], status: request.status_code} }},
        routes: {total: routes.size, methods: routes.map { |route| route["method"] }.tally,
                 recent: routes.first(100).map { |route| {method: route["method"], path: route["path"][0, 512], handler: route["handler"][0, 256]} }},
        series:  {memory: memory_series(120), latency: latency_series(120), traffic: traffic_series(24)},
        tracing: {histogram: latency_histogram.map { |b| {label: b.label, count: b.count} },
                  slowest: slowest_requests.map { |request| {method: request.method, path: Env.redact_url(request.path)[0, 512], ms: request.processing_time} },
                  endpoints: endpoint_stats.map { |e| {name: e.name[0, 256], count: e.count, avg_ms: e.avg, p95_ms: e.p95, max_ms: e.max, error_rate: e.error_rate} }},
        profiler: {spans: profiler_spans.map { |name, values| {name: name[0, 256], values: values} }, leak_suspected: memory_leak_suspected?},
        cache:    {total: cache.total, gets: cache.gets, sets: cache.sets, deletes: cache.deletes,
                hit_rate: cache.gets > 0 ? cache.hit_rate : nil, error_rate: cache.error_rate, avg_ms: cache.avg_ms,
                written_bytes: cache.written_bytes, breakdown: cache_breakdown,
                recent: recent_cache_operations.map { |op| {at: op.timestamp.to_rfc3339, operation: op.operation, store: op.store_type, ms: op.processing_time, hit: op.hit, failed: !op.successful?} }},
        components: {active: components.active, mounts: components.mounts, unmounts: components.unmounts,
                     refreshes: components.refreshes, avg_age: components.avg_age,
                     recent: recent_component_events.map { |e| {at: e.timestamp.to_rfc3339, type: e.component_type[0, 256], event: e.event, ms: e.processing_time, memory_delta: e.memory_delta} }},
        database: {active: database.active, queries: database.queries, slow: database.slow, n_plus_one: database.n_plus_one,
                   avg_ms: database.avg_ms, errors: database.errors, pool_waits: database.pool_waits,
                   transactions: database_transactions.map { |transaction| {id: transaction.id, nested: transaction.nested, state: transaction.state, ms: transaction.duration_ms} }},
      }
    end
  end
end

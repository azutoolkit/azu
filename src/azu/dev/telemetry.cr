require "json"
require "socket"

module Azu
  module Dev
    # Reports to `azu dev`'s dashboard. `azu dev` creates a Unix socket (mode 0600) and passes its path as
    # AZU_TELEMETRY_SOCKET; in development the app connects and writes one JSON snapshot per line, once a second:
    # requests (with `PERFORMANCE_MONITORING=true`), SQL from the `QueryStore`, and the GC heap. No route is exposed,
    # a snapshot that cannot be sent is dropped, and nothing runs without the variable.
    module Telemetry
      VERSION  = 1
      INTERVAL = 1.second
      RECENT   = 30

      @@started = false

      def self.start(config : Configuration, path : String? = ENV["AZU_TELEMETRY_SOCKET"]?) : Nil
        return if @@started || path.nil? || path.empty? || !config.env.development?

        @@started = true
        spawn(name: "azu-telemetry") { report(config, path) }
      end

      private def self.report(config : Configuration, path : String) : Nil
        socket : UNIXSocket? = nil
        loop do
          sleep INTERVAL
          begin
            socket ||= UNIXSocket.new(path)
            socket.puts snapshot(config).to_json
            socket.flush
          rescue IO::Error | Socket::Error
            socket.try(&.close) rescue nil
            socket = nil # azu dev went away or is restarting: try again next time
          end
        end
      end

      def self.snapshot(config : Configuration, metrics : PerformanceMetrics? = config.performance_monitor.try(&.metrics),
                        queries : QueryStore = QueryStore.instance, now : Time = Clock.now)
        {
          v:        VERSION,
          at:       now.to_rfc3339,
          requests: metrics.try { |monitored| requests(monitored, now) },
          sql:      sql(queries, config.database.slow_query_ms),
          errors:   errors(ErrorStore.instance),
          runtime:  {heap_bytes: GC.stats.heap_size.to_i64, free_bytes: GC.stats.free_bytes.to_i64},
        }
      end

      def self.requests(metrics : PerformanceMetrics, now : Time)
        recent = metrics.recent_requests(500)
        last_ten = recent.count { |request| now - request.timestamp <= 10.seconds }
        times = recent.map(&.processing_time).sort!
        rows = recent.last(RECENT).reverse.map do |request|
          {at: request.timestamp.to_local.to_s("%H:%M:%S"), method: request.method, path: request.path,
           status: request.status_code, ms: request.processing_time.round(2), endpoint: request.endpoint}
        end
        {
          total:      metrics.aggregate_stats.total_requests,
          rps:        (last_ten / 10.0).round(2),
          p50_ms:     percentile(times, 0.5),
          p95_ms:     percentile(times, 0.95),
          errors_4xx: recent.count { |request| 400 <= request.status_code < 500 },
          errors_5xx: recent.count { |request| request.status_code >= 500 },
          recent:     rows,
        }
      end

      def self.sql(queries : QueryStore, slow_ms : Number)
        recent = queries.queries(limit: 500)
        pool = queries.pool.try do |snapshot|
          {open: snapshot.open, idle: snapshot.idle, in_flight: snapshot.in_flight, max: snapshot.max}
        end
        alerts = queries.n_plus_one.first(3).map do |alert|
          {sql: alert.normalized_sql, count: alert.count, endpoint: alert.endpoint, caller: alert.caller, suggestion: alert.suggestion}
        end
        slowest = recent.sort_by { |query| -query.duration_ms }.first(5).map { |query| {sql: query.normalized_sql, ms: query.duration_ms.round(2)} }
        {
          total:      recent.size,
          avg_ms:     recent.empty? ? 0.0 : (recent.sum(&.duration_ms) / recent.size).round(2),
          slow:       slow_ms > 0 ? recent.count { |query| query.duration_ms >= slow_ms } : 0,
          pool:       pool,
          n_plus_one: alerts,
          slowest:    slowest,
          recent:     recent.last(100).reverse.map { |query|
            {id: query.id, at: Time.unix_ms(query.started_ms).to_s("%H:%M:%S"), sql: query.normalized_sql[0, 2000],
             ms: query.duration_ms.round(2), caller: query.caller, model: query.table, endpoint: query.endpoint,
             pool_wait_ms: query.pool_wait_ms.round(2)}
          },
          histogram: histogram(recent.map(&.duration_ms)),
        }
      end

      # No raw request/context or bound SQL parameters cross the local telemetry socket.
      # RequestInfo has already applied the exception page's redaction policy.
      def self.errors(store : ErrorStore)
        store.recent(10).map do |report|
          {id: report.id, at: report.timestamp.to_s("%H:%M:%S"), class: report.exception_class,
           message: report.message[0, 2000], route: report.request.route || report.request.line,
           params: report.request.params.first(30).map { |key, value| {key[0, 128], value[0, 512]} },
           frames: report.frames.first(40).map { |frame| frame.raw[0, 512] },
           problem: {type: "about:blank", title: report.status_text, status: report.status,
                     detail: report.message[0, 2000], instance: report.request.path, error_id: report.error_id}}
        end
      end

      def self.histogram(times : Array(Float64))
        bounds = [1.0, 5.0, 10.0, 50.0, 100.0]
        labels = ["<1", "1–5", "5–10", "10–50", "50–100", "≥100"]
        counts = Array.new(6, 0)
        times.each do |ms|
          next unless ms.finite? && ms >= 0
          counts[bounds.index { |bound| ms < bound } || 5] += 1
        end
        maximum = Math.max(1, counts.max)
        labels.map_with_index { |label, index| {label: label, count: counts[index], bar: counts[index] * 12 // maximum} }
      end

      private def self.percentile(sorted : Array(Float64), rank : Float64) : Float64
        return 0.0 if sorted.empty?
        sorted[((sorted.size - 1) * rank).round.to_i].round(2)
      end

      # For specs.
      def self.reset : Nil
        @@started = false
      end
    end
  end

  Instrumentation.on_prepare { |config| Dev::Telemetry.start(config) }
end

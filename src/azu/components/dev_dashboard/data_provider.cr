require "../../performance_metrics"
require "../../development_tools"
require "./format"
require "./status"
require "./database_data"

module Azu
  module Components
    # Collects everything the development dashboard displays.
    #
    # One instance serves one render (the component is built per request), so the
    # aggregates several views share are memoized for the instance lifetime
    # instead of being recomputed: each one would otherwise copy and sort the
    # whole retained request window.
    class DashboardDataProvider
      include Dashboard::DatabaseData

      alias Format = Dashboard::Format
      alias Status = Dashboard::Status
      alias Level = Dashboard::Level

      # Requests retained by PerformanceMetrics (its MAX_METRICS cap).
      REQUEST_WINDOW = 10_000
      # How many of the newest requests the error views inspect.
      ERROR_WINDOW = 50
      # Verbs Azu registers implicitly next to GET routes; hidden from the route views.
      IMPLICIT_VERBS = %w[HEAD OPTIONS]
      VERB_ORDER     = %w[GET POST PUT PATCH DELETE]
      # Lower edges (ms) of the latency histogram buckets.
      HISTOGRAM_EDGES  = [0.0, 10.0, 50.0, 100.0, 300.0, 1000.0]
      HISTOGRAM_LABELS = ["< 10 ms", "10-50 ms", "50-100 ms", "100-300 ms", "0.3-1 s", ">= 1 s"]

      record Latency, p50 : Float64, p95 : Float64, p99 : Float64, avg : Float64
      record Insight, status : Status, message : String, detail : String, tab : String
      record EndpointStat, name : String, count : Int32, avg : Float64, p95 : Float64, max : Float64, error_rate : Float64
      record CacheStats, total : Int32, gets : Int32, sets : Int32, deletes : Int32,
        hit_rate : Float64, error_rate : Float64, avg_ms : Float64, written_bytes : Float64
      record ComponentStats, active : Int32, mounts : Int32, unmounts : Int32, refreshes : Int32, avg_age : Float64
      record Runtime, crystal : String, environment : String, pid : Int64, heap : UInt64, free : UInt64, total : UInt64
      record Bucket, label : String, count : Int32, status : Status

      # One titled group of key/value rows inside a log entry's inspector.
      record Pane, title : String, rows : Array(Tuple(String, String))
      record LogEntry, time : Time, level : Level, tag : String, message : String,
        status : Int32?, duration_ms : Float64?, panes : Array(Pane) do
        # Plain-text rendering, used both for clipboard copies and as the search haystack.
        def to_text : String
          String.build do |io|
            io << Format.clock(time) << ' ' << level.to_s.upcase << ' ' << tag << ' ' << message
            status.try { |code| io << ' ' << code }
            duration_ms.try { |millis| io << ' ' << Format.ms(millis) }
            panes.each do |pane|
              io << '\n' << pane.title << ':'
              pane.rows.each { |key, value| io << "\n  " << key << ": " << value }
            end
          end
        end
      end

      getter start_time : Time

      @requests : Array(PerformanceMetrics::RequestMetric)?
      @stats : PerformanceMetrics::AggregatedStats?
      @cache_stats : CacheStats?
      @routes : Array(Hash(String, String))?

      def initialize(@metrics : PerformanceMetrics, @start_time : Time, @log : ::Log)
      end

      def uptime : Time::Span
        Time.utc - @start_time
      end

      # Resident set size of this process, nil where the OS does not expose it.
      def rss_bytes : Int64?
        kilobytes = if File.exists?("/proc/self/status")
                      File.read("/proc/self/status")[/^VmRSS:\s+(\d+)\s+kB/m, 1]?.try(&.to_i64)
                    else
                      ps_rss_kilobytes
                    end
        kilobytes.try { |amount| amount * 1024 }
      rescue File::Error | IO::Error
        nil
      end

      def runtime : Runtime
        gc = GC.stats
        Runtime.new(Crystal::VERSION, Azu.current_config.env.to_s, Process.pid.to_i64, gc.heap_size, gc.free_bytes, gc.total_bytes)
      end

      # Profiler spans by total time spent, empty while the profiler is disabled or unused.
      def profiler_spans(limit : Int32 = 10) : Array(Tuple(String, Hash(String, Float64)))
        DevelopmentTools.profiler.stats.to_a.sort_by! { |_, span| -span["total_time_ms"] }.first(limit)
      end

      # GC heap samples (MB) from the memory leak detector; empty unless it is monitoring.
      def memory_series(points : Int32 = 40) : Array(Float64)
        DevelopmentTools.memory_detector.recent_snapshots(points).map { |snapshot| snapshot.heap_size / 1024.0 / 1024.0 }
      end

      def memory_leak_suspected? : Bool
        DevelopmentTools.memory_detector.analyze_leak.leak_detected?
      rescue
        false # analyze_leak raises until the first snapshot exists
      end

      # --- Requests ---------------------------------------------------------

      # The retained request window, oldest first.
      def requests : Array(PerformanceMetrics::RequestMetric)
        @requests ||= @metrics.recent_requests(REQUEST_WINDOW)
      end

      def stats : PerformanceMetrics::AggregatedStats
        @stats ||= @metrics.aggregate_stats
      end

      # Latency percentiles of the request window, nil until a request is recorded.
      getter latency : Latency? do
        unless requests.empty?
          sorted = requests.map(&.processing_time).sort!
          Latency.new(percentile(sorted, 0.5), percentile(sorted, 0.95), percentile(sorted, 0.99), sorted.sum / sorted.size)
        end
      end

      def requests_per_second : Float64
        seconds = (Time.utc - @metrics.start_time).total_seconds
        seconds > 0 ? stats.total_requests / seconds : 0.0
      end

      # Durations (ms) of the newest requests, oldest first.
      def latency_series(points : Int32 = 40) : Array(Float64)
        requests.last(points).map(&.processing_time)
      end

      # Request counts in `points` equal time buckets spanning the request window.
      def traffic_series(points : Int32 = 24) : Array(Float64)
        buckets = Array(Float64).new(points, 0.0)
        return buckets if requests.size < 2

        oldest = requests.first.timestamp
        width = ((requests.last.timestamp - oldest).total_seconds / points).clamp(0.001, Float64::MAX)
        requests.each { |request| buckets[((request.timestamp - oldest).total_seconds / width).to_i.clamp(0, points - 1)] += 1 }
        buckets
      end

      def latency_histogram : Array(Bucket)
        counts = Array.new(HISTOGRAM_EDGES.size, 0)
        requests.each { |request| counts[HISTOGRAM_EDGES.rindex { |edge| request.processing_time >= edge } || 0] += 1 }
        HISTOGRAM_EDGES.map_with_index { |edge, i| Bucket.new(HISTOGRAM_LABELS[i], counts[i], Status.latency(edge)) }
      end

      def slowest_requests(limit : Int32 = 8) : Array(PerformanceMetrics::RequestMetric)
        requests.sort_by(&.processing_time).last(limit).reverse!
      end

      # Per-endpoint latency, slowest average first.
      def endpoint_stats(limit : Int32 = 15) : Array(EndpointStat)
        rows = requests.group_by(&.endpoint).map do |name, group|
          times = group.map(&.processing_time).sort!
          EndpointStat.new(name, group.size, times.sum / times.size, percentile(times, 0.95), times.last, group.count(&.error?) * 100.0 / group.size)
        end
        rows.sort_by!(&.avg).reverse!.first(limit)
      end

      # Errors (4xx/5xx) among the newest requests, newest first.
      def recent_errors : Array(PerformanceMetrics::RequestMetric)
        requests.last(ERROR_WINDOW).select(&.error?).reverse!
      end

      # --- Log stream -------------------------------------------------------

      # Request, cache and component events merged into one newest-first stream.
      def log_entries(requests_limit : Int32 = 100, events_limit : Int32 = 25) : Array(LogEntry)
        entries = requests.last(requests_limit).map { |request| request_entry(request) }
        entries.concat @metrics.recent_caches(events_limit).map { |operation| cache_entry(operation) }
        entries.concat @metrics.recent_components(events_limit).map { |event| component_entry(event) }
        entries.sort_by!(&.time).reverse!
      end

      # --- Application ------------------------------------------------------

      # Registered routes without implicit HEAD/OPTIONS, ordered by path then verb.
      def routes : Array(Hash(String, String))
        @routes ||= Azu.current_config.router.route_info
          .reject { |route| IMPLICIT_VERBS.includes?(route["method"]) }
          .sort_by! { |route| {route["path"], VERB_ORDER.index(route["method"]) || VERB_ORDER.size} }
      end

      # Class names of the handlers passed to Azu.start, in execution order.
      def pipeline : Array(String)
        Azu.current_config.handlers.map(&.class.name)
      end

      # --- Cache and components --------------------------------------------

      def cache_stats : CacheStats
        @cache_stats ||= begin
          raw = @metrics.cache_stats
          CacheStats.new(
            total: raw.fetch("total_operations", 0.0).to_i,
            gets: raw.fetch("get_operations", 0.0).to_i,
            sets: raw.fetch("set_operations", 0.0).to_i,
            deletes: raw.fetch("delete_operations", 0.0).to_i,
            hit_rate: raw.fetch("hit_rate", 0.0),
            error_rate: raw.fetch("error_rate", 0.0),
            avg_ms: raw.fetch("avg_processing_time", 0.0),
            written_bytes: raw.fetch("total_data_written", 0.0))
        end
      end

      def cache_breakdown : Hash(String, Hash(String, Float64))
        @metrics.cache_operation_breakdown
      end

      def recent_cache_operations(limit : Int32 = 20) : Array(PerformanceMetrics::CacheMetric)
        @metrics.recent_caches(limit).reverse!
      end

      def component_stats : ComponentStats
        raw = @metrics.component_stats
        ComponentStats.new(
          active: raw.fetch("total_components", 0.0).to_i,
          mounts: raw.fetch("mount_events", 0.0).to_i,
          unmounts: raw.fetch("unmount_events", 0.0).to_i,
          refreshes: raw.fetch("refresh_events", 0.0).to_i,
          avg_age: raw.fetch("avg_component_age", 0.0))
      end

      def recent_component_events(limit : Int32 = 20) : Array(PerformanceMetrics::ComponentMetric)
        @metrics.recent_components(limit).reverse!
      end

      # --- Health -----------------------------------------------------------

      def health_score : Int32
        penalties = [
          (stats.error_rate * 5).to_i.clamp(0, 30),
          latency_penalty,
          cache_penalty,
          (database_stats.n_plus_one * 5).clamp(0, 15),
          (database_stats.slow * 2).clamp(0, 10),
        ]
        (100 - penalties.sum).clamp(0, 100)
      end

      # Things worth the developer's attention, most severe first.
      def insights : Array(Insight)
        [error_insight, latency_insight, n_plus_one_insight, cache_insight, slow_query_insight].compact.sort_by!(&.status).reverse!
      end

      private def percentile(sorted : Array(Float64), quantile : Float64) : Float64
        sorted[(quantile * (sorted.size - 1)).to_i]
      end

      # Off Linux there is no /proc, so ask `ps` (one short-lived process per render).
      private def ps_rss_kilobytes : Int64?
        output = IO::Memory.new
        Process.run("ps", ["-o", "rss=", "-p", Process.pid.to_s], output: output)
        output.to_s.strip.to_i64?
      end

      # 5xx is an error; 4xx and latency spikes are warnings.
      private def request_level(request : PerformanceMetrics::RequestMetric) : Level
        if request.status_code >= 500
          Level::Error
        elsif request.error? || Status.latency(request.processing_time).bad?
          Level::Warn
        else
          Level::Info
        end
      end

      private def request_entry(request : PerformanceMetrics::RequestMetric) : LogEntry
        LogEntry.new(request.timestamp, request_level(request), request.method, request.path, request.status_code, request.processing_time, [
          Pane.new("Request", [{"Method", request.method}, {"Path", request.path}, {"Endpoint", request.endpoint}, {"Request ID", request.request_id || "n/a"}]),
          Pane.new("Response", [
            {"Status", request.status_code.to_s}, {"Duration", Format.ms(request.processing_time)},
            {"Memory before", Format.megabytes(request.memory_before)}, {"Memory after", Format.megabytes(request.memory_after)},
            {"Memory delta", Format.megabytes(request.memory_delta)},
          ]),
        ])
      end

      private def cache_entry(operation : PerformanceMetrics::CacheMetric) : LogEntry
        result = operation.hit? ? "hit" : (operation.miss? ? "miss" : "n/a")
        LogEntry.new(operation.timestamp, operation.successful? ? Level::Debug : Level::Error, "cache", "#{operation.operation.upcase} #{operation.key}", nil, operation.processing_time, [
          Pane.new("Cache operation", [
            {"Operation", operation.operation}, {"Key", operation.key}, {"Store", operation.store_type}, {"Result", result},
            {"TTL", operation.ttl_seconds.try { |seconds| "#{seconds}s" } || "n/a"}, {"Error", operation.error || "none"},
          ]),
        ])
      end

      private def component_entry(event : PerformanceMetrics::ComponentMetric) : LogEntry
        LogEntry.new(event.timestamp, Level::Debug, "component", "#{event.component_type} #{event.event}", nil, event.processing_time, [
          Pane.new("Component", [
            {"Type", event.component_type}, {"ID", event.component_id}, {"Event", event.event},
            {"Memory delta", event.memory_delta.try { |bytes| Format.megabytes(bytes) } || "n/a"},
            {"Age", event.age_at_event.try { |age| Format.uptime(age) } || "n/a"},
          ]),
        ])
      end

      private def latency_penalty : Int32
        avg = latency.try(&.avg) || 0.0
        avg > 200 ? ((avg - 200) / 50).to_i.clamp(0, 20) : 0
      end

      # Only penalise a low hit rate once there are cache reads to judge it by.
      private def cache_penalty : Int32
        cache = cache_stats
        cache.gets > 0 && cache.hit_rate < 70 ? ((70 - cache.hit_rate) / 5).to_i.clamp(0, 15) : 0
      end

      private def error_insight : Insight?
        rate = stats.error_rate
        return if rate <= 2

        Insight.new(rate > 5 ? Status::Bad : Status::Warn, rate > 5 ? "High error rate detected" : "Elevated error rate", "#{Format.percent(rate)} of requests are failing", "logs")
      end

      private def latency_insight : Insight?
        p95 = latency.try(&.p95) || 0.0
        Insight.new(Status::Warn, "Slow response times detected", "p95 response time is #{Format.ms(p95)}", "tracing") if p95 > 500
      end

      private def n_plus_one_insight : Insight?
        db = database_stats
        return if db.n_plus_one.zero?

        if db.critical > 0
          Insight.new(Status::Bad, "Critical N+1 query patterns detected", "#{db.critical} critical #{pattern_noun(db.critical)} found", "database")
        else
          Insight.new(Status::Warn, "N+1 query patterns detected", "#{db.n_plus_one} #{pattern_noun(db.n_plus_one)} found", "database")
        end
      end

      private def pattern_noun(count : Int) : String
        count == 1 ? "pattern" : "patterns"
      end

      private def cache_insight : Insight?
        cache = cache_stats
        return unless cache.total > 100

        if cache.hit_rate < 50
          Insight.new(Status::Warn, "Low cache hit rate", "Only #{Format.percent(cache.hit_rate)} hit rate across #{cache.total} operations", "cache")
        elsif cache.hit_rate < 70
          Insight.new(Status::Idle, "Cache could be more effective", "#{Format.percent(cache.hit_rate)} hit rate - consider caching frequently read data", "cache")
        end
      end

      private def slow_query_insight : Insight?
        slow = database_stats.slow
        Insight.new(Status::Warn, "Multiple slow queries detected", "#{slow} slow queries recorded", "database") if slow > 10
      end
    end
  end
end

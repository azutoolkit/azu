require "../component"
require "../performance_metrics"
require "../performance_reporter"
require "../development_tools"
require "../cache"

# Conditionally require CQL if available
{% begin %}
  {% if @top_level.has_constant?("CQL") %}
    # CQL is available, performance monitoring enabled
  {% else %}
    # CQL not available, using fallback implementations
  {% end %}
{% end %}

module Azu
  module Components
    # Data provider for the development dashboard.
    # This class is responsible for collecting all the data needed by the dashboard.
    class DashboardDataProvider
      @metrics : PerformanceMetrics
      @start_time : Time
      @log : ::Log

      def initialize(@metrics : PerformanceMetrics, @start_time : Time, @log : ::Log)
      end

      def collect_app_status_data
        uptime = Time.utc - @start_time
        current_memory = PerformanceMetrics.current_memory_usage
        aggregate_stats = @metrics.aggregate_stats

        {
          "uptime_seconds"  => uptime.total_seconds.to_i,
          "uptime_human"    => format_duration(uptime),
          "memory_usage_mb" => (current_memory / 1024.0 / 1024.0).round(2),
          "total_requests"  => aggregate_stats.total_requests,
          "error_rate"      => aggregate_stats.error_rate.round(2),
          "cpu_usage"       => get_cpu_usage_mock,
        }
      end

      def collect_performance_data
        aggregate_stats = @metrics.aggregate_stats

        {
          "avg_response_time_ms"      => aggregate_stats.avg_response_time.round(2),
          "p95_response_time_ms"      => aggregate_stats.p95_response_time.round(2),
          "p99_response_time_ms"      => aggregate_stats.p99_response_time.round(2),
          "avg_memory_usage_mb"       => aggregate_stats.avg_memory_usage.round(2),
          "peak_memory_usage_mb"      => aggregate_stats.peak_memory_usage.round(2),
          "total_memory_allocated_mb" => (aggregate_stats.total_memory_allocated / 1024.0 / 1024.0).round(2),
          "requests_per_second"       => calculate_requests_per_second,
        }
      end

      def collect_cache_data
        cache_stats = @metrics.cache_stats

        {
          "total_operations"       => cache_stats["total_operations"]?.try(&.to_i) || 0_i32,
          "hit_rate"               => cache_stats["hit_rate"]?.try(&.round(2)) || 0.0,
          "error_rate"             => cache_stats["error_rate"]?.try(&.round(2)) || 0.0,
          "avg_processing_time_ms" => cache_stats["avg_processing_time"]?.try(&.round(2)) || 0.0,
          "total_data_written_mb"  => ((cache_stats["total_data_written"]? || 0.0) / 1024.0 / 1024.0).round(2),
          "get_operations"         => cache_stats["get_operations"]?.try(&.to_i) || 0_i32,
          "set_operations"         => cache_stats["set_operations"]?.try(&.to_i) || 0_i32,
          "delete_operations"      => cache_stats["delete_operations"]?.try(&.to_i) || 0_i32,
        }
      end

      def collect_cache_breakdown_data
        breakdown = @metrics.cache_operation_breakdown
        breakdown
      end

      def collect_cache_breakdown_count : Int32
        breakdown = @metrics.cache_operation_breakdown
        breakdown.values.sum(&.["count"].to_i)
      end

      def collect_recent_cache_operations(limit : Int32 = 20)
        recent_caches = @metrics.recent_caches(limit)
        recent_caches.map do |cache_op|
          {
            "key"                => cache_op.key,
            "operation"          => cache_op.operation,
            "store_type"         => cache_op.store_type,
            "hit"                => cache_op.hit?.to_s || "N/A",
            "processing_time_ms" => cache_op.processing_time.round(2),
            "key_size"           => cache_op.key_size,
            "value_size"         => cache_op.value_size.to_s || "N/A",
            "ttl_seconds"        => cache_op.ttl_seconds.to_s || "N/A",
            "error"              => cache_op.error || "None",
            "timestamp"          => cache_op.timestamp.to_s,
            "successful"         => cache_op.successful?.to_s || "false",
          }
        end
      end

      def collect_database_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          metrics = monitor.metrics_summary
          stats = monitor.query_profiler.statistics
          slow_queries = monitor.query_profiler.slow_queries
          n_plus_one_issues = monitor.n_plus_one_detector.issues

          # Calculate aggregate stats from query statistics
          total_queries = stats.values.sum(&.execution_count)
          slow_query_count = slow_queries.size
          avg_time = stats.empty? ? 0.0 : stats.values.sum(&.avg_time.total_milliseconds) / stats.size
          min_time = stats.empty? ? 0.0 : stats.values.min_of(&.min_time.total_milliseconds)
          max_time = stats.empty? ? 0.0 : stats.values.max_of(&.max_time.total_milliseconds)

          {
            "total_queries"         => total_queries.to_i64,
            "slow_queries"          => slow_query_count.to_i64,
            "very_slow_queries"     => slow_queries.count { |q| q.execution_time.total_milliseconds > 500 }.to_i64,
            "error_queries"         => 0_i64,
            "avg_query_time"        => avg_time,
            "min_query_time"        => min_time,
            "max_query_time"        => max_time,
            "error_rate"            => 0.0,
            "queries_per_second"    => 0.0,
            "slow_query_rate"       => total_queries > 0 ? (slow_query_count.to_f / total_queries * 100) : 0.0,
            "n_plus_one_patterns"   => n_plus_one_issues.size,
            "critical_n_plus_one"   => n_plus_one_issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::Critical },
            "high_n_plus_one"       => n_plus_one_issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::High },
            "database_health_score" => begin
              # Calculate health score inline
              health = 100
              health -= [metrics.slow_queries * 2, 30].min
              health -= [metrics.n_plus_one_patterns * 5, 25].min
              health -= metrics.avg_query_time > 100 ? [((metrics.avg_query_time - 100) / 50).to_i, 20].min : 0
              health.clamp(0, 100)
            end,
            "monitoring_enabled" => monitor.enabled?,
            "uptime"             => metrics.uptime,
          }
        {% else %}
          # CQL not available - return default values
          {
            "total_queries"         => 0_i64,
            "slow_queries"          => 0_i64,
            "very_slow_queries"     => 0_i64,
            "error_queries"         => 0_i64,
            "avg_query_time"        => 0.0,
            "min_query_time"        => 0.0,
            "max_query_time"        => 0.0,
            "error_rate"            => 0.0,
            "queries_per_second"    => 0.0,
            "slow_query_rate"       => 0.0,
            "n_plus_one_patterns"   => 0,
            "critical_n_plus_one"   => 0,
            "high_n_plus_one"       => 0,
            "database_health_score" => 100,
            "monitoring_enabled"    => false,
            "uptime"                => Time::Span.zero,
          }
        {% end %}
      rescue ex
        @log.error { "Failed to collect database metrics: #{ex.message}" }
        {
          "total_queries"         => 0_i64,
          "slow_queries"          => 0_i64,
          "very_slow_queries"     => 0_i64,
          "error_queries"         => 0_i64,
          "avg_query_time"        => 0.0,
          "min_query_time"        => 0.0,
          "max_query_time"        => 0.0,
          "error_rate"            => 0.0,
          "queries_per_second"    => 0.0,
          "slow_query_rate"       => 0.0,
          "n_plus_one_patterns"   => 0,
          "critical_n_plus_one"   => 0,
          "high_n_plus_one"       => 0,
          "database_health_score" => 100,
          "monitoring_enabled"    => false,
          "uptime"                => Time::Span.zero,
        }
      end

      def collect_database_summary_count : Int32
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          metrics = monitor.metrics_summary
          metrics.total_queries + metrics.slow_queries + metrics.n_plus_one_patterns
        {% else %}
          0 # CQL not available
        {% end %}
      rescue ex : Exception
        0
      end

      def collect_query_profiler_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          stats = monitor.query_profiler.statistics
          slowest = monitor.query_profiler.slowest_queries(10)

          total_executions = stats.values.sum(&.execution_count)
          max_time = stats.empty? ? 0.0 : stats.values.max_of(&.max_time.total_milliseconds)
          most_frequent = stats.values.max_by?(&.execution_count)

          {
            "unique_patterns"       => stats.size,
            "total_executions"      => total_executions.to_i64,
            "avg_performance_score" => begin
              # Calculate average performance score across all query patterns
              if stats.empty?
                100.0
              else
                total_score = stats.values.sum do |stat|
                  score = 100.0
                  score -= [(stat.execution_count - 100) / 50.0, 30.0].min if stat.execution_count > 100
                  score -= [(stat.avg_time.total_milliseconds - 50) / 25.0, 40.0].min if stat.avg_time.total_milliseconds > 50
                  score.clamp(0.0, 100.0)
                end
                total_score / stats.size
              end
            end,
            "slowest_pattern_time" => max_time,
            "most_frequent_count"  => (most_frequent.try(&.execution_count) || 0).to_i64,
          }
        {% else %}
          # CQL not available - return default values
          {
            "unique_patterns"       => 0,
            "total_executions"      => 0_i64,
            "avg_performance_score" => 0.0,
            "slowest_pattern_time"  => 0.0,
            "most_frequent_count"   => 0_i64,
          }
        {% end %}
      rescue ex
        @log.error { "Failed to collect query profiler data: #{ex.message}" }
        {
          "unique_patterns"       => 0,
          "total_executions"      => 0_i64,
          "avg_performance_score" => 0.0,
          "slowest_pattern_time"  => 0.0,
          "most_frequent_count"   => 0_i64,
        }
      end

      def collect_n_plus_one_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          issues = monitor.n_plus_one_detector.issues

          {
            "issues"         => issues.map { |i| {message: i.message, severity: i.severity.to_s, type: i.type}.to_json },
            "total_issues"   => issues.size,
            "critical_count" => issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::Critical },
            "high_count"     => issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::High },
            "medium_count"   => issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::Medium },
            "low_count"      => issues.count { |i| i.severity == CQL::Performance::PerformanceIssue::Severity::Low },
          }
        {% else %}
          # CQL not available - return default values
          {
            "issues"         => [] of String,
            "total_issues"   => 0,
            "critical_count" => 0,
            "high_count"     => 0,
            "medium_count"   => 0,
            "low_count"      => 0,
          }
        {% end %}
      rescue ex
        @log.error { "Failed to collect N+1 data: #{ex.message}" }
        {
          "issues"         => [] of String,
          "total_issues"   => 0,
          "critical_count" => 0,
          "high_count"     => 0,
          "medium_count"   => 0,
          "low_count"      => 0,
        }
      end

      def collect_slow_queries_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          slow_queries = monitor.query_profiler.slow_queries(20)

          slow_queries.map do |query|
            {
              "sql"               => query.sql,
              "normalized_sql"    => query.sql.gsub(/\?/, "?").gsub(/\d+/, "?").gsub(/'[^']*'/, "?").gsub(/"[^"]*"/, "?").gsub(/\s+/, " ").strip,
              "context"           => query.context || "N/A",
              "timestamp"         => query.timestamp.to_rfc3339,
              "rows_affected"     => query.rows_affected || 0_i64,
              "error"             => "None",
              "execution_time_ms" => query.execution_time.total_milliseconds,
            }
          end
        {% else %}
          # CQL not available - return empty array
          [] of Hash(String, String | Float64 | Int64)
        {% end %}
      rescue ex
        @log.error { "Failed to collect slow queries data: #{ex.message}" }
        [] of Hash(String, String | Float64 | Int64)
      end

      def collect_query_patterns_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          stats = monitor.query_profiler.statistics

          # Sort by execution count descending and take top 15
          sorted_patterns = stats.values.sort_by(&.execution_count).reverse[0..15]

          sorted_patterns.map do |stat|
            {
              "normalized_sql"    => stat.normalized_sql,
              "execution_count"   => stat.execution_count.to_i64,
              "avg_time_ms"       => stat.avg_time.total_milliseconds,
              "performance_score" => begin
                # Calculate performance score for single query pattern
                score = 100.0
                score -= [(stat.execution_count - 100) / 50.0, 30.0].min if stat.execution_count > 100
                score -= [(stat.avg_time.total_milliseconds - 50) / 25.0, 40.0].min if stat.avg_time.total_milliseconds > 50
                score -= [(stat.max_time.total_milliseconds - 200) / 100.0, 20.0].min if stat.max_time.total_milliseconds > 200
                score.clamp(0.0, 100.0)
              end,
            }
          end
        {% else %}
          # CQL not available - return empty array
          [] of Hash(String, String | Float64 | Int64)
        {% end %}
      rescue ex
        @log.error { "Failed to collect query patterns data: #{ex.message}" }
        [] of Hash(String, String | Int64 | Float64)
      end

      def collect_error_logs
        recent_requests = @metrics.recent_requests(50)
        errors = recent_requests.select(&.error?)

        errors.map do |error_request|
          {
            "timestamp"          => error_request.timestamp.to_s,
            "method"             => error_request.method,
            "path"               => error_request.path,
            "status_code"        => error_request.status_code.to_s,
            "processing_time_ms" => error_request.processing_time.round(2).to_s,
            "endpoint"           => error_request.endpoint,
            "memory_delta_mb"    => error_request.memory_usage_mb.to_s,
            "category"           => error_request.status_code >= 500 ? "5xx Server Error" : "4xx Client Error",
          }
        end
      end

      private def calculate_requests_per_second : Float64
        uptime = Time.utc - @start_time
        total_requests = @metrics.aggregate_stats.total_requests

        return 0.0 if uptime.total_seconds <= 0
        total_requests.to_f / uptime.total_seconds
      end

      private def get_cpu_usage_mock : Float64
        15.5 + Random.rand(10.0)
      end

      private def format_duration(span : Time::Span) : String
        if span.total_hours >= 1
          "#{span.total_hours.to_i}h #{span.minutes}m #{span.seconds}s"
        elsif span.total_minutes >= 1
          "#{span.minutes}m #{span.seconds}s"
        else
          "#{span.seconds}s"
        end
      end

      private def calculate_performance_score(query_metrics) : Float64
        {% if @top_level.has_constant?("CQL") %}
          return 0.0 if query_metrics.total_queries == 0

          # Calculate score based on various metrics
          base_score = 100.0

          # Penalize for slow queries
          slow_query_penalty = (query_metrics.slow_query_rate * 0.5)

          # Penalize for errors
          error_penalty = (query_metrics.error_rate * 2.0)

          # Penalize for high average execution time (assuming > 100ms is bad)
          avg_time_penalty = (query_metrics.avg_execution_time.total_milliseconds / 100.0) * 10.0

          score = base_score - slow_query_penalty - error_penalty - avg_time_penalty
          [score, 0.0].max
        {% else %}
          0.0
        {% end %}
      end

      private def calculate_query_performance_score(pattern : NamedTuple(sql: String, count: Int64, avg_time: Time::Span)) : Float64
        {% if @top_level.has_constant?("CQL") %}
          # Base score starts at 100
          score = 100.0

          # Penalize for high execution count (assuming > 1000 is concerning)
          count_penalty = (pattern[:count] / 1000.0) * 10.0

          # Penalize for high average time (assuming > 100ms is concerning)
          time_penalty = (pattern[:avg_time].total_milliseconds / 100.0) * 20.0

          score = score - count_penalty - time_penalty
          [score, 0.0].max
        {% else %}
          0.0
        {% end %}
      end

      private def calculate_database_health_score(metrics) : Int32
        {% if @top_level.has_constant?("CQL") %}
          # Placeholder implementation
          100
        {% else %}
          100
        {% end %}
      end

      def collect_routes_data
        routes = Azu::CONFIG.router.route_info
        routes.sort_by! { |route| [route["method"], route["path"]] }
        routes
      rescue ex
        @log.error { "Could not collect route information: #{ex.message}" }
        [{
          "method"      => "ERROR",
          "path"        => "/routes-unavailable",
          "resource"    => "N/A",
          "handler"     => "Router",
          "description" => "Route collection failed: #{ex.message}",
        }]
      end

      def collect_component_data
        component_stats = @metrics.component_stats

        {
          "total_components"          => component_stats["total_components"]?.try(&.to_i) || 0_i32,
          "mount_events"              => component_stats["mount_events"]?.try(&.to_i) || 0_i32,
          "unmount_events"            => component_stats["unmount_events"]?.try(&.to_i) || 0_i32,
          "refresh_events"            => component_stats["refresh_events"]?.try(&.to_i) || 0_i32,
          "avg_component_age_seconds" => component_stats["avg_component_age"]?.try(&.round(2)) || 0.0,
        }
      end

      def collect_component_count : Int32
        component_stats = @metrics.component_stats
        component_stats["total_components"]?.try(&.to_i) || 0_i32
      end

      def collect_recent_component_events(limit : Int32 = 20)
        recent_components = @metrics.recent_components(limit)
        recent_components.map do |component|
          {
            "component_id"         => component.component_id,
            "component_type"       => component.component_type,
            "event"                => component.event,
            "processing_time_ms"   => component.processing_time.try(&.round(2).to_s) || "N/A",
            "memory_before_mb"     => component.memory_before.try { |memory_bytes| (memory_bytes / 1024.0 / 1024.0).round(2).to_s } || "N/A",
            "memory_after_mb"      => component.memory_after.try { |memory_bytes| (memory_bytes / 1024.0 / 1024.0).round(2).to_s } || "N/A",
            "memory_delta_mb"      => component.memory_delta.try { |memory_bytes| (memory_bytes / 1024.0 / 1024.0).round(2).to_s } || "N/A",
            "age_at_event_seconds" => component.age_at_event.try(&.total_seconds.round(2).to_s) || "N/A",
            "timestamp"            => component.timestamp.to_s,
          }
        end
      end

      def collect_system_data
        gc_stats = GC.stats

        {
          "crystal_version"   => Crystal::VERSION,
          "environment"       => Azu::CONFIG.env.to_s,
          "process_id"        => Process.pid.to_i32,
          "gc_heap_size_mb"   => (gc_stats.heap_size / 1024.0 / 1024.0).round(2),
          "gc_free_bytes_mb"  => (gc_stats.free_bytes / 1024.0 / 1024.0).round(2),
          "gc_total_bytes_mb" => (gc_stats.total_bytes / 1024.0 / 1024.0).round(2),
        }
      end

      def collect_test_data
        {
          "last_run"                => "2024-01-15 10:30:00 UTC",
          "coverage_percent"        => 87.5,
          "failed_tests"            => 2_i32,
          "test_suite_time_seconds" => 45.2,
          "total_tests"             => 156_i32,
        }
      end

      # Four Golden Signals data collection
      def collect_golden_metrics
        perf = collect_performance_data
        app = collect_app_status_data
        system = collect_system_data

        # Calculate saturation (memory as % of typical limit)
        memory_mb = app["memory_usage_mb"].as(Float64)
        memory_pct = (memory_mb / 512.0 * 100).clamp(0.0, 100.0) # Assume 512MB baseline

        avg_latency = perf["avg_response_time_ms"].as(Float64)
        error_rate = app["error_rate"].as(Float64)

        {
          latency: {
            avg:    avg_latency,
            p50:    (avg_latency * 0.8).round(2),
            p95:    perf["p95_response_time_ms"].as(Float64),
            p99:    perf["p99_response_time_ms"].as(Float64),
            status: latency_status(avg_latency),
          },
          traffic: {
            rps:    perf["requests_per_second"].as(Float64),
            total:  app["total_requests"].as(Int32 | Int64).to_i64,
            status: "normal",
          },
          errors: {
            rate:   error_rate,
            count:  collect_error_logs.size,
            status: error_status(error_rate),
          },
          saturation: {
            memory_pct: memory_pct,
            gc_heap_mb: system["gc_heap_size_mb"].as(Float64),
            status:     saturation_status(memory_pct),
          },
        }
      end

      # Collect latency sparkline data from recent requests
      # Returns an array of response times (ms) for the last N requests
      def collect_latency_sparkline_data(points : Int32 = 20) : Array(Float64)
        recent = @metrics.recent_requests(points)
        recent.map(&.processing_time)
      end

      # Collect traffic sparkline data by bucketing requests into time windows
      # Returns an array of request counts per time bucket
      def collect_traffic_sparkline_data(points : Int32 = 20) : Array(Float64)
        recent = @metrics.recent_requests(points * 10) # Get more data for bucketing
        return Array(Float64).new(points, 0.0) if recent.empty?

        # Create time buckets based on available data range
        return [recent.size.to_f] if recent.size < 2

        oldest = recent.first.timestamp
        newest = recent.last.timestamp
        time_range = newest - oldest

        # If time range is too small, just return counts per bucket
        bucket_duration = time_range / points
        bucket_duration = 1.second if bucket_duration.total_seconds < 1

        buckets = Array(Float64).new(points, 0.0)
        recent.each do |req|
          bucket_index = ((req.timestamp - oldest) / bucket_duration).to_i
          bucket_index = bucket_index.clamp(0, points - 1)
          buckets[bucket_index] += 1.0
        end

        buckets
      end

      private def latency_status(avg_ms : Float64) : String
        avg_ms < 100 ? "healthy" : (avg_ms < 500 ? "warning" : "critical")
      end

      private def error_status(rate : Float64) : String
        rate < 1.0 ? "healthy" : (rate < 5.0 ? "warning" : "critical")
      end

      private def saturation_status(pct : Float64) : String
        pct < 70 ? "healthy" : (pct < 85 ? "warning" : "critical")
      end
    end

    # Development Dashboard Component using AdminKit Framework
    # Provides comprehensive metrics for developers during development phase
    # Built with AdminKit's professional admin dashboard framework
    class DevDashboardComponent
      include Component

      getter metrics : PerformanceMetrics
      getter log : ::Log
      @start_time : Time
      @data_provider : DashboardDataProvider

      def initialize(@metrics : PerformanceMetrics? = nil, @log : ::Log = Azu::CONFIG.log)
        @metrics = @metrics || Azu::CONFIG.performance_monitor.try(&.metrics) || PerformanceMetrics.new
        @start_time = Time.utc
        @data_provider = DashboardDataProvider.new(@metrics, @start_time, @log)
      end

      def content
        raw "<!DOCTYPE html>"
        html lang: "en" do
          head do
            meta charset: "UTF-8"
            meta name: "viewport", content: "width=device-width, initial-scale=1.0"
            title "Azu Development Dashboard"

            link rel: "preconnect", href: "https://fonts.googleapis.com"
            link rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "anonymous"
            link href: "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap", rel: "stylesheet"
            link rel: "stylesheet", href: "https://unpkg.com/lucide-static@latest/font/lucide.css"
            script src: "https://unpkg.com/lucide@latest/dist/umd/lucide.js"

            style do
              raw custom_styles
            end
          end

          body do
            div class: "app-layout" do
              render_sidebar
              div class: "main-content" do
                render_top_bar
                render_alert_banner
                render_content_area
              end
            end
            render_keyboard_shortcuts_modal
            render_scripts
          end
        end
      end

      private def render_sidebar
        aside class: "sidebar" do
          div class: "sidebar-header" do
            a href: "#", class: "sidebar-brand" do
              i "data-lucide": "gem"
              span "Azu Dev"
            end
          end

          nav class: "sidebar-nav" do
            div class: "nav-section" do
              div class: "nav-section-title" do
                text "Overview"
              end
              button class: "nav-item active", onclick: "showSection('overview')", "data-section": "overview" do
                i "data-lucide": "gauge"
                span "Dashboard"
              end
              button class: "nav-item", onclick: "showSection('errors')", "data-section": "errors" do
                i "data-lucide": "alert-circle"
                span "Errors"
                error_count = @data_provider.collect_error_logs.size
                if error_count > 0
                  span class: "nav-item-badge error" do
                    text error_count.to_s
                  end
                end
              end
            end

            div class: "nav-section" do
              div class: "nav-section-title" do
                text "Performance"
              end
              button class: "nav-item", onclick: "showSection('requests')", "data-section": "requests" do
                i "data-lucide": "activity"
                span "Requests"
              end
              button class: "nav-item", onclick: "showSection('database')", "data-section": "database" do
                i "data-lucide": "database"
                span "Database"
                db_data = @data_provider.collect_database_data
                slow_queries = db_data["slow_queries"].as(Int64 | Int32)
                if slow_queries > 0
                  span class: "nav-item-badge warning" do
                    text slow_queries.to_s
                  end
                end
              end
              button class: "nav-item", onclick: "showSection('cache')", "data-section": "cache" do
                i "data-lucide": "hard-drive"
                span "Cache"
              end
            end

            div class: "nav-section" do
              div class: "nav-section-title" do
                text "Application"
              end
              button class: "nav-item", onclick: "showSection('routes')", "data-section": "routes" do
                i "data-lucide": "route"
                span "Routes"
                span class: "nav-item-badge default" do
                  text @data_provider.collect_routes_data.size.to_s
                end
              end
              button class: "nav-item", onclick: "showSection('components')", "data-section": "components" do
                i "data-lucide": "layers"
                span "Components"
                span class: "nav-item-badge default" do
                  text @data_provider.collect_component_count.to_s
                end
              end
            end
          end

          div class: "sidebar-footer" do
            div class: "theme-toggle-container" do
              span class: "theme-toggle-label" do
                text "Theme"
              end
              div class: "theme-toggle-buttons", id: "theme-toggle" do
                button class: "theme-btn", "data-theme": "light", title: "Light mode", onclick: "setTheme('light')" do
                  i "data-lucide": "sun"
                end
                button class: "theme-btn", "data-theme": "dark", title: "Dark mode", onclick: "setTheme('dark')" do
                  i "data-lucide": "moon"
                end
                button class: "theme-btn", "data-theme": "system", title: "System preference", onclick: "setTheme('system')" do
                  i "data-lucide": "monitor"
                end
              end
            end
            div class: "status-indicator" do
              span class: "status-dot"
              span id: "connection-status" do
                text "Live"
              end
              span class: "last-updated", id: "last-updated" do
                text "Updated now"
              end
            end
          end
        end
      end

      private def render_top_bar
        header class: "top-bar" do
          div class: "top-bar-left" do
            render_health_score
            render_quick_stats
          end
          div class: "top-bar-right" do
            button class: "btn btn-ghost btn-icon", onclick: "window.location.reload()", title: "Refresh (r)" do
              i "data-lucide": "refresh-cw"
            end
            button class: "btn btn-ghost btn-icon", onclick: "exportMetrics()", title: "Export (e)" do
              i "data-lucide": "download"
            end
            button class: "btn btn-ghost btn-icon", onclick: "toggleAutoRefresh()", title: "Toggle Auto-refresh" do
              i "data-lucide": "timer", id: "auto-refresh-icon"
            end
            button class: "btn btn-ghost btn-icon", onclick: "showShortcuts()", title: "Keyboard shortcuts (?)" do
              i "data-lucide": "keyboard"
            end
          end
        end
      end

      private def render_health_score
        health = calculate_health_score
        health_class = health >= 90 ? "healthy" : (health >= 70 ? "warning" : "critical")
        health_label = health >= 90 ? "Healthy" : (health >= 70 ? "Warning" : "Critical")

        # SVG circle math: circumference = 2 * PI * r, where r = 18
        circumference = 113.1
        offset = circumference - (health / 100.0) * circumference

        div class: "health-score" do
          div class: "health-ring" do
            raw <<-SVG
            <svg width="48" height="48" viewBox="0 0 48 48">
              <circle class="health-ring-bg" cx="24" cy="24" r="18"/>
              <circle class="health-ring-progress #{health_class}" cx="24" cy="24" r="18"
                      stroke-dasharray="#{circumference}"
                      stroke-dashoffset="#{offset}"/>
            </svg>
            SVG
            span class: "health-value" do
              text health.to_s
            end
          end
          span class: "health-label #{health_class}" do
            text health_label
          end
        end
      end

      private def render_quick_stats
        app_data = @data_provider.collect_app_status_data
        perf_data = @data_provider.collect_performance_data
        cache_data = @data_provider.collect_cache_data

        div class: "quick-stats" do
          div class: "quick-stat" do
            span class: "quick-stat-label" do
              text "Requests"
            end
            span class: "quick-stat-value" do
              text format_number(app_data["total_requests"].as(Int32 | Int64))
            end
          end

          div class: "quick-stat" do
            span class: "quick-stat-label" do
              text "Avg Response"
            end
            span class: "quick-stat-value" do
              text "#{perf_data["avg_response_time_ms"]}ms"
            end
          end

          div class: "quick-stat" do
            span class: "quick-stat-label" do
              text "Error Rate"
            end
            error_rate = app_data["error_rate"].as(Float64)
            trend_class = error_rate > 2.0 ? "trend-down" : "trend-up"
            span class: "quick-stat-value #{trend_class}" do
              text "#{error_rate}%"
            end
          end

          div class: "quick-stat" do
            span class: "quick-stat-label" do
              text "Cache Hit"
            end
            hit_rate = cache_data["hit_rate"].as(Float64)
            trend_class = hit_rate >= 80.0 ? "trend-up" : "trend-down"
            span class: "quick-stat-value #{trend_class}" do
              text "#{hit_rate}%"
            end
          end
        end
      end

      private def render_alert_banner
        insights = collect_insights
        critical_insights = insights.select { |i| i[:severity] == "critical" }
        warning_insights = insights.select { |i| i[:severity] == "warning" }

        return if critical_insights.empty? && warning_insights.empty?

        banner_class = !critical_insights.empty? ? "alert-banner" : "alert-banner warning"

        div class: banner_class do
          i class: "alert-icon", "data-lucide": !critical_insights.empty? ? "alert-triangle" : "alert-circle"
          div class: "alert-content" do
            span class: "alert-title" do
              text "#{critical_insights.size + warning_insights.size} issue#{"s" if (critical_insights.size + warning_insights.size) > 1} need attention"
            end
            ul class: "alert-list" do
              (critical_insights + warning_insights).first(3).each do |insight|
                li do
                  text insight[:message]
                end
              end
            end
          end
          span class: "alert-action", onclick: "showSection('overview')" do
            text "View Details"
          end
        end
      end

      private def render_content_area
        div class: "content-area" do
          render_overview_section
          render_errors_section
          render_requests_section
          render_database_section
          render_cache_section
          render_routes_section
          render_components_section
        end
      end

      private def render_golden_metrics_panel
        metrics = @data_provider.collect_golden_metrics

        div class: "golden-metrics" do
          # LATENCY Signal
          div class: "golden-signal" do
            div class: "golden-signal-header" do
              span class: "golden-signal-title" { text "Latency" }
              i "data-lucide": "timer"
            end
            div class: "golden-signal-value text-#{metrics[:latency][:status]}" do
              text "#{metrics[:latency][:avg].round(1)}ms"
            end
            render_sparkline_svg(@data_provider.collect_latency_sparkline_data)
            div class: "golden-signal-details" do
              span { text "p50: #{metrics[:latency][:p50]}ms" }
              span { text "p95: #{metrics[:latency][:p95]}ms" }
              span { text "p99: #{metrics[:latency][:p99]}ms" }
            end
            div class: "golden-signal-status" do
              span class: "card-status-dot #{metrics[:latency][:status]}"
              text metrics[:latency][:status].capitalize
            end
          end

          # TRAFFIC Signal
          div class: "golden-signal" do
            div class: "golden-signal-header" do
              span class: "golden-signal-title" { text "Traffic" }
              i "data-lucide": "activity"
            end
            div class: "golden-signal-value" do
              text "#{metrics[:traffic][:rps].round(1)}/s"
            end
            render_sparkline_svg(@data_provider.collect_traffic_sparkline_data)
            div class: "golden-signal-details" do
              span { text "Total: #{format_number(metrics[:traffic][:total])}" }
            end
            div class: "golden-signal-status" do
              span class: "card-status-dot healthy"
              text "Normal"
            end
          end

          # ERRORS Signal
          div class: "golden-signal" do
            div class: "golden-signal-header" do
              span class: "golden-signal-title" { text "Errors" }
              i "data-lucide": "alert-circle"
            end
            div class: "golden-signal-value text-#{metrics[:errors][:status]}" do
              text "#{metrics[:errors][:rate].round(2)}%"
            end
            div class: "golden-signal-details" do
              span { text "#{metrics[:errors][:count]} errors in last 5min" }
            end
            div class: "golden-signal-status" do
              span class: "card-status-dot #{metrics[:errors][:status]}"
              text metrics[:errors][:status].capitalize
            end
          end

          # SATURATION Signal
          div class: "golden-signal" do
            div class: "golden-signal-header" do
              span class: "golden-signal-title" { text "Saturation" }
              i "data-lucide": "gauge"
            end
            div class: "golden-signal-value text-#{metrics[:saturation][:status]}" do
              text "#{metrics[:saturation][:memory_pct].round(0)}%"
            end
            div class: "progress", style: "margin: var(--space-2) 0" do
              div class: "progress-bar #{metrics[:saturation][:status]}",
                style: "width: #{metrics[:saturation][:memory_pct]}%"
            end
            div class: "golden-signal-details" do
              span { text "Memory: #{metrics[:saturation][:memory_pct].round(1)}%" }
              span { text "GC Heap: #{metrics[:saturation][:gc_heap_mb].round(1)}MB" }
            end
            div class: "golden-signal-status" do
              span class: "card-status-dot #{metrics[:saturation][:status]}"
              text metrics[:saturation][:status].capitalize
            end
          end
        end
      end

      private def render_overview_section
        div id: "overview", class: "section active" do
          # Golden Metrics Panel - Four Golden Signals (PRIMARY FOCUS)
          render_golden_metrics_panel

          # Insights Panel
          render_insights_panel

          # Quick metrics grid
          div class: "grid grid-cols-3 mb-6" do
            render_performance_card_v2
            render_app_status_card_v2
            render_cache_summary_card
          end

          div class: "grid grid-cols-3 mb-6" do
            render_database_summary_card
            render_component_summary_card
            render_system_info_card
          end

          # Test Results (if available)
          render_test_results_card
        end
      end

      private def render_errors_section
        div id: "errors", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Error Logs"
            end
            para class: "section-description" do
              text "Recent application errors and failed requests"
            end
          end
          render_errors_table
        end
      end

      private def render_requests_section
        div id: "requests", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Request Performance"
            end
            para class: "section-description" do
              text "Detailed request metrics and endpoint analysis"
            end
          end

          div class: "grid grid-cols-2 mb-6" do
            render_performance_card_v2
            render_throughput_card
          end
        end
      end

      private def render_database_section
        div id: "database", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Database Performance"
            end
            para class: "section-description" do
              text "Query metrics, slow queries, and N+1 detection"
            end
          end

          div class: "grid grid-cols-3 mb-6" do
            render_database_overview_cards
            render_query_performance_card
            render_n_plus_one_analysis_card
          end

          render_slow_queries_table
          render_query_patterns_table
        end
      end

      private def render_cache_section
        div id: "cache", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Cache Performance"
            end
            para class: "section-description" do
              text "Cache hit rates, operations, and efficiency metrics"
            end
          end

          div class: "grid grid-cols-3 mb-6" do
            render_cache_overview_cards
            render_cache_operations_card
            render_cache_performance_card
          end

          render_cache_breakdown_table
          render_recent_cache_operations_table
        end
      end

      private def render_routes_section
        div id: "routes", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Application Routes"
            end
            para class: "section-description" do
              text "Registered endpoints and route handlers"
            end
          end
          render_routes_table
        end
      end

      private def render_components_section
        div id: "components", class: "section" do
          div class: "section-header" do
            h2 class: "section-title" do
              text "Component Lifecycle"
            end
            para class: "section-description" do
              text "Live component events and performance tracking"
            end
          end

          div class: "grid grid-cols-3 mb-6" do
            render_component_overview_cards
            render_component_events_card
            render_component_performance_card
          end

          render_recent_component_events_table
        end
      end

      private def render_keyboard_shortcuts_modal
        div id: "shortcuts-modal", class: "shortcuts-modal" do
          div class: "shortcuts-content" do
            h3 class: "shortcuts-title" do
              text "Keyboard Shortcuts"
            end

            div class: "shortcut-group" do
              div class: "shortcut-group-title" do
                text "Navigation"
              end
              render_shortcut_item("g o", "Go to Overview")
              render_shortcut_item("g e", "Go to Errors")
              render_shortcut_item("g q", "Go to Requests")
              render_shortcut_item("g d", "Go to Database")
              render_shortcut_item("g c", "Go to Cache")
              render_shortcut_item("g r", "Go to Routes")
              render_shortcut_item("g p", "Go to Components")
            end

            div class: "shortcut-group" do
              div class: "shortcut-group-title" do
                text "Actions"
              end
              render_shortcut_item("r", "Refresh data")
              render_shortcut_item("/", "Focus search")
              render_shortcut_item("e", "Export metrics")
              render_shortcut_item("?", "Show shortcuts")
              render_shortcut_item("Esc", "Close modal")
            end
          end
        end
      end

      private def render_shortcut_item(keys : String, label : String)
        div class: "shortcut-item" do
          span class: "shortcut-label" do
            text label
          end
          span class: "shortcut-key" do
            keys.split(" ").each do |key|
              kbd key
            end
          end
        end
      end

      # ===== New Card Renderers =====

      private def render_insights_panel
        insights = collect_insights
        return if insights.empty?

        div class: "insights-panel" do
          div class: "insights-header" do
            span class: "insights-title" do
              i "data-lucide": "lightbulb"
              text "Insights"
            end
            button class: "btn btn-ghost btn-icon", onclick: "dismissInsights()" do
              i "data-lucide": "x"
            end
          end

          insights.first(5).each do |insight|
            div class: "insight-item" do
              span class: "insight-severity #{insight[:severity]}"
              div class: "insight-content" do
                div class: "insight-message" do
                  text insight[:message]
                end
                div class: "insight-detail" do
                  text insight[:detail]
                end
                if action = insight[:action]?
                  span class: "insight-action", onclick: action do
                    text "View details"
                  end
                end
              end
            end
          end
        end
      end

      private def render_performance_card_v2
        perf_data = @data_provider.collect_performance_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "zap"
              text "Response Time"
            end
          end
          div class: "card-content" do
            div class: "metric-with-sparkline" do
              div class: "metric-block" do
                span class: "metric-block-label" do
                  text "Average"
                end
                span class: "metric-block-value text-crystal" do
                  text "#{perf_data["avg_response_time_ms"]}ms"
                end
                div class: "metric-block-sub" do
                  span "p50: #{perf_data["avg_response_time_ms"].as(Float64) * 0.8}ms"
                  span "p95: #{perf_data["p95_response_time_ms"]}ms"
                end
              end
              div class: "metric-block" do
                span class: "metric-block-label" do
                  text "P99"
                end
                span class: "metric-block-value" do
                  text "#{perf_data["p99_response_time_ms"]}ms"
                end
                div class: "sparkline-container" do
                  render_sparkline_svg(@data_provider.collect_latency_sparkline_data)
                end
              end
            end
          end
          div class: "card-status" do
            avg = perf_data["avg_response_time_ms"].as(Float64)
            status = avg < 100 ? "healthy" : (avg < 300 ? "warning" : "critical")
            span class: "card-status-dot #{status}"
            text avg < 100 ? "All endpoints performing well" : "Some endpoints may need optimization"
          end
        end
      end

      private def render_app_status_card_v2
        data = @data_provider.collect_app_status_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "monitor"
              text "Application Status"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_row("Uptime", data["uptime_human"].to_s, "healthy")
              render_metric_row("Memory", "#{data["memory_usage_mb"]} MB", nil)
              render_metric_row("Total Requests", format_number(data["total_requests"].as(Int32 | Int64)), nil)
              error_rate = data["error_rate"].as(Float64)
              error_status = error_rate < 1 ? "healthy" : (error_rate < 5 ? "warning" : "critical")
              render_metric_row("Error Rate", "#{error_rate}%", error_status)
            end
          end
        end
      end

      private def render_cache_summary_card
        data = @data_provider.collect_cache_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "hard-drive"
              text "Cache"
            end
          end
          div class: "card-content" do
            hit_rate = data["hit_rate"].as(Float64)

            div class: "metric-block", style: "margin-bottom: var(--space-4)" do
              span class: "metric-block-label" do
                text "Hit Rate"
              end
              span class: "metric-block-value #{hit_rate >= 80 ? "text-performance" : "text-accent"}" do
                text "#{hit_rate}%"
              end
              div class: "progress", style: "margin-top: var(--space-2)" do
                progress_class = hit_rate >= 80 ? "healthy" : (hit_rate >= 50 ? "warning" : "critical")
                div class: "progress-bar #{progress_class}", style: "width: #{hit_rate}%"
              end
            end

            div class: "metric-list" do
              render_metric_row("Total Ops", data["total_operations"].to_s, nil)
              render_metric_row("Avg Time", "#{data["avg_processing_time_ms"]}ms", nil)
            end
          end
        end
      end

      private def render_database_summary_card
        data = @data_provider.collect_database_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "database"
              text "Database"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_row("Total Queries", data["total_queries"].to_s, nil)
              slow = data["slow_queries"].as(Int64 | Int32)
              render_metric_row("Slow Queries", slow.to_s, slow > 0 ? "warning" : "healthy")
              n_plus_one = data["n_plus_one_patterns"].as(Int32)
              render_metric_row("N+1 Patterns", n_plus_one.to_s, n_plus_one > 0 ? "critical" : "healthy")
              render_metric_row("Avg Time", "#{data["avg_query_time"].as(Float64).round(2)}ms", nil)
            end
          end
        end
      end

      private def render_component_summary_card
        data = @data_provider.collect_component_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "layers"
              text "Components"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_row("Active", data["total_components"].to_s, nil)
              render_metric_row("Mounts", data["mount_events"].to_s, nil)
              render_metric_row("Refreshes", data["refresh_events"].to_s, nil)
              render_metric_row("Avg Age", "#{data["avg_component_age_seconds"].as(Float64).round(1)}s", nil)
            end
          end
        end
      end

      private def render_system_info_card
        data = @data_provider.collect_system_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "cpu"
              text "System"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_row("Crystal", data["crystal_version"].to_s, nil)
              render_metric_row("Environment", data["environment"].to_s, nil)
              render_metric_row("GC Heap", "#{data["gc_heap_size_mb"]} MB", nil)
              render_metric_row("Process ID", data["process_id"].to_s, nil)
            end
          end
        end
      end

      private def render_throughput_card
        perf_data = @data_provider.collect_performance_data

        div class: "metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "trending-up"
              text "Throughput"
            end
          end
          div class: "card-content" do
            div class: "metric-block" do
              span class: "metric-block-label" do
                text "Requests/Second"
              end
              span class: "metric-block-value text-performance" do
                text "#{perf_data["requests_per_second"].as(Float64).round(2)}"
              end
              div class: "sparkline-container" do
                render_sparkline_svg(@data_provider.collect_traffic_sparkline_data)
              end
            end
          end
        end
      end

      private def render_metric_row(label : String, value : String, status : String?)
        div class: "metric-item" do
          span class: "metric-label" do
            text label
          end
          span class: "metric-value #{status ? status : ""}" do
            text value
          end
        end
      end

      private def render_sparkline_svg(data : Array(Float64))
        # Render empty sparkline if no data
        if data.empty? || data.all?(&.zero?)
          raw <<-SVG
          <svg class="sparkline" viewBox="0 0 100 32" preserveAspectRatio="none">
            <path class="sparkline-line" d="M0 16 L100 16" stroke-opacity="0.3"/>
          </svg>
          SVG
          return
        end

        # Normalize data to fit in viewBox (0-100 width, 0-32 height)
        min_val = data.min
        max_val = data.max
        range = max_val - min_val
        range = 1.0 if range == 0 # Avoid division by zero

        # Calculate points (x scales 0-100, y scales 2-30 with padding)
        points = data.map_with_index do |val, i|
          x = (i.to_f / (data.size - 1).clamp(1, Int32::MAX)) * 100
          y = 30 - ((val - min_val) / range * 28) + 2 # Invert y, add padding
          {x: x.round(1), y: y.round(1)}
        end

        # Build SVG path for line
        line_path = String.build do |str|
          points.each_with_index do |point, i|
            str << (i == 0 ? "M" : " L")
            str << point[:x] << " " << point[:y]
          end
        end

        # Build SVG path for filled area (line + close to bottom)
        area_path = String.build do |str|
          str << "M0 32 L0 " << points.first[:y]
          points.each do |point|
            str << " L" << point[:x] << " " << point[:y]
          end
          str << " L100 32 Z"
        end

        raw <<-SVG
        <svg class="sparkline" viewBox="0 0 100 32" preserveAspectRatio="none">
          <path class="sparkline-area" d="#{area_path}"/>
          <path class="sparkline-line" d="#{line_path}"/>
        </svg>
        SVG
      end

      private def render_errors_table
        error_logs = @data_provider.collect_error_logs

        div class: "table-card" do
          div class: "table-header" do
            span class: "table-title" do
              i "data-lucide": "alert-circle"
              text "Recent Errors"
            end
            div class: "table-search" do
              i "data-lucide": "search"
              input type: "text", placeholder: "Filter errors...", id: "error-search", onkeyup: "filterTable('errors-table', this.value)"
            end
          end

          if error_logs.empty?
            div class: "empty-state" do
              i "data-lucide": "check-circle"
              h4 "No recent errors"
              para do
                text "Your application is running smoothly."
              end
            end
          else
            div class: "table-container" do
              table class: "table", id: "errors-table" do
                thead do
                  tr do
                    th "Time"
                    th "Status"
                    th "Method"
                    th "Path"
                    th "Duration"
                    th "Endpoint"
                  end
                end
                tbody do
                  error_logs.each do |error|
                    error_hash = error.as(Hash)
                    status_code = error_hash["status_code"].as(String).to_i
                    badge_class = status_code >= 500 ? "badge-destructive" : "badge-warning"

                    tr class: "expandable-row" do
                      td class: "text-muted-foreground" do
                        text format_timestamp(error_hash["timestamp"].as(String))
                      end
                      td do
                        span class: "badge #{badge_class}" do
                          text error_hash["status_code"]
                        end
                      end
                      td do
                        span class: "badge badge-method #{error_hash["method"].as(String).downcase}" do
                          text error_hash["method"]
                        end
                      end
                      td do
                        code error_hash["path"]
                      end
                      td "#{error_hash["processing_time_ms"]}ms"
                      td error_hash["endpoint"]
                    end
                  end
                end
              end
            end
            render_table_pagination(error_logs.size)
          end
        end
      end

      private def render_routes_table
        routes = @data_provider.collect_routes_data

        div class: "table-card" do
          div class: "table-header" do
            span class: "table-title" do
              i "data-lucide": "route"
              text "Registered Routes"
            end
            div class: "table-search" do
              i "data-lucide": "search"
              input type: "text", placeholder: "Filter routes...", id: "routes-search", onkeyup: "filterTable('routes-table', this.value)"
            end
          end

          if routes.empty?
            div class: "empty-state" do
              i "data-lucide": "info"
              h4 "No routes found"
              para do
                text "Routes information requires router.routes method."
              end
            end
          else
            div class: "table-container" do
              table class: "table", id: "routes-table" do
                thead do
                  tr do
                    th "Method"
                    th "Path"
                    th "Handler"
                    th "Description"
                  end
                end
                tbody do
                  routes.each do |route|
                    route_hash = route.as(Hash)
                    method = route_hash["method"].as(String)
                    next if method.downcase == "options" || method.downcase == "head"

                    tr do
                      td do
                        span class: "badge badge-method #{method.downcase}" do
                          text method
                        end
                      end
                      td do
                        code route_hash["path"]
                      end
                      td route_hash["handler"]
                      td class: "text-muted-foreground" do
                        text route_hash["description"]
                      end
                    end
                  end
                end
              end
            end
            render_table_pagination(routes.size)
          end
        end
      end

      private def render_table_pagination(total : Int32)
        div class: "table-pagination" do
          span "Showing #{[total, 20].min} of #{total} entries"
          div class: "pagination-controls" do
            button class: "pagination-btn", disabled: true do
              text "Prev"
            end
            button class: "pagination-btn active" do
              text "1"
            end
            if total > 20
              button class: "pagination-btn" do
                text "2"
              end
            end
            if total > 40
              button class: "pagination-btn" do
                text "3"
              end
            end
            button class: "pagination-btn", disabled: total <= 20 do
              text "Next"
            end
          end
        end
      end

      # ===== Helper Methods =====

      private def calculate_health_score : Int32
        score = 100

        # Penalize for high error rate
        error_rate = @data_provider.collect_app_status_data["error_rate"].as(Float64)
        score -= (error_rate * 5).to_i.clamp(0, 30)

        # Penalize for slow response times
        perf_data = @data_provider.collect_performance_data
        avg_response = perf_data["avg_response_time_ms"].as(Float64)
        if avg_response > 200
          score -= ((avg_response - 200) / 50).to_i.clamp(0, 20)
        end

        # Penalize for low cache hit rate
        cache_data = @data_provider.collect_cache_data
        hit_rate = cache_data["hit_rate"].as(Float64)
        if hit_rate < 70
          score -= ((70 - hit_rate) / 5).to_i.clamp(0, 15)
        end

        # Penalize for N+1 queries
        db_data = @data_provider.collect_database_data
        n_plus_one = db_data["n_plus_one_patterns"].as(Int32)
        score -= (n_plus_one * 5).clamp(0, 15)

        # Penalize for slow queries
        slow_queries = db_data["slow_queries"].as(Int64 | Int32)
        score -= (slow_queries.to_i * 2).clamp(0, 10)

        score.clamp(0, 100)
      end

      private def collect_insights : Array(NamedTuple(severity: String, message: String, detail: String, action: String?))
        insights = [] of NamedTuple(severity: String, message: String, detail: String, action: String?)

        # Check error rate
        error_rate = @data_provider.collect_app_status_data["error_rate"].as(Float64)
        if error_rate > 5
          insights << {severity: "critical", message: "High error rate detected", detail: "#{error_rate}% of requests are failing", action: "showSection('errors')"}
        elsif error_rate > 2
          insights << {severity: "warning", message: "Elevated error rate", detail: "#{error_rate}% of requests are failing", action: "showSection('errors')"}
        end

        # Check response time
        perf_data = @data_provider.collect_performance_data
        p95 = perf_data["p95_response_time_ms"].as(Float64)
        if p95 > 500
          insights << {severity: "warning", message: "Slow response times detected", detail: "P95 response time is #{p95}ms", action: "showSection('requests')"}
        end

        # Check N+1 queries
        db_data = @data_provider.collect_database_data
        n_plus_one = db_data["n_plus_one_patterns"].as(Int32)
        if n_plus_one > 0
          critical_n1 = db_data["critical_n_plus_one"].as(Int32)
          if critical_n1 > 0
            insights << {severity: "critical", message: "Critical N+1 query patterns detected", detail: "#{critical_n1} critical patterns found", action: "showSection('database')"}
          else
            insights << {severity: "warning", message: "N+1 query patterns detected", detail: "#{n_plus_one} patterns found", action: "showSection('database')"}
          end
        end

        # Check cache hit rate
        cache_data = @data_provider.collect_cache_data
        hit_rate = cache_data["hit_rate"].as(Float64)
        total_ops = cache_data["total_operations"].as(Int32)
        if total_ops > 100 && hit_rate < 50
          insights << {severity: "warning", message: "Low cache hit rate", detail: "Only #{hit_rate}% cache hit rate with #{total_ops} operations", action: "showSection('cache')"}
        elsif total_ops > 100 && hit_rate < 70
          insights << {severity: "info", message: "Cache could be more effective", detail: "#{hit_rate}% hit rate - consider caching more frequently accessed data", action: "showSection('cache')"}
        end

        # Check slow queries
        slow_queries = db_data["slow_queries"].as(Int64 | Int32)
        if slow_queries > 10
          insights << {severity: "warning", message: "Multiple slow queries detected", detail: "#{slow_queries} slow queries recorded", action: "showSection('database')"}
        end

        insights
      end

      private def format_number(n : Int32 | Int64) : String
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
      end

      private def format_timestamp(timestamp : String) : String
        # Simple timestamp formatting - just show relative time
        "#{timestamp.split(" ").first?.try(&.split("T").last?.try(&.split(".").first)) || timestamp}"
      end

      # ===== Legacy Tab Renderers (kept for backwards compatibility) =====

      private def render_dashboard_tab
        render_overview_section
      end

      private def render_errors_tab
        render_errors_section
      end

      private def render_routes_tab
        render_routes_section
      end

      private def render_database_tab
        render_database_section
      end

      private def render_cache_tab
        render_cache_section
      end

      private def render_components_tab
        render_components_section
      end

      private def render_dashboard_tab
        div id: "dashboard", class: "tab-pane active" do
          # First Row of Metrics
          div class: "grid grid-cols-3 mb-6" do
            render_app_status_card
            render_performance_card
            render_cache_card
          end

          # Second Row of Metrics
          div class: "grid grid-cols-3 mb-6" do
            render_database_card
            render_component_card
            render_system_card
          end

          # Test Results
          render_test_results_card
        end
      end

      private def render_errors_tab
        div id: "errors", class: "tab-pane" do
          error_logs = @data_provider.collect_error_logs

          if error_logs.empty?
            div class: "empty-state" do
              i "data-lucide": "check"
              h4 "No recent errors!"
              para class: "header-text" do
                text "Your application is running smoothly."
              end
            end
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Timestamp"
                    th "Method"
                    th "Path"
                    th "Status"
                    th "Time"
                    th "Endpoint"
                    th "Category"
                  end
                end
                tbody do
                  error_logs.each do |error|
                    error_hash = error.as(Hash)
                    status_code = error_hash["status_code"].as(String)
                    badge_class = status_code.starts_with?("5") ? "badge-destructive" : "badge-outline"

                    tr do
                      td class: "text-muted-foreground" do
                        small error_hash["timestamp"]
                      end
                      td do
                        span class: "badge badge-outline" do
                          text error_hash["method"]
                        end
                      end
                      td do
                        code error_hash["path"]
                      end
                      td do
                        span class: "badge #{badge_class}" do
                          text status_code
                        end
                      end
                      td "#{error_hash["processing_time_ms"]}ms"
                      td error_hash["endpoint"]
                      td error_hash["category"]
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_database_tab
        div id: "database", class: "tab-pane" do
          # Database Overview Cards
          div class: "grid grid-cols-3 mb-6" do
            render_database_overview_cards
            render_query_performance_card
            render_n_plus_one_analysis_card
          end
          # Detailed Query Tables
          render_slow_queries_table
          render_query_patterns_table
        end
      end

      private def render_database_overview_cards
        data = @data_provider.collect_database_data

        render_metric_card "Query Performance Stats", "bar-chart-3" do
          div class: "metric-list" do
            render_metric_item "Total Queries", data["total_queries"].to_s, "text-primary"
            render_metric_item "Queries/Second", data["queries_per_second"].as(Float64).round(2).to_s, "text-performance"
            render_metric_item "Avg Query Time", "#{data["avg_query_time"].as(Float64).round(2)}ms", "text-crystal"
            render_metric_item "Min Query Time", "#{data["min_query_time"].as(Float64).round(2)}ms", "text-performance"
            render_metric_item "Max Query Time", "#{data["max_query_time"].as(Float64).round(2)}ms",
              data["max_query_time"].as(Float64) > 1000.0 ? "text-destructive" : "text-accent"
            render_metric_item "Error Rate", "#{data["error_rate"].as(Float64).round(2)}%",
              data["error_rate"].as(Float64) > 1.0 ? "text-destructive" : "text-crystal"
            render_metric_item "Health Score", "#{data["database_health_score"]}/100",
              data["database_health_score"].as(Int32) > 80 ? "text-performance" : "text-destructive"
          end
        end
      end

      private def render_query_performance_card
        profiler_data = @data_provider.collect_query_profiler_data

        render_metric_card "Query Patterns", "bar-chart-3" do
          div class: "metric-list" do
            render_metric_item "Unique Patterns", profiler_data["unique_patterns"].to_s, "text-primary"
            render_metric_item "Total Executions", profiler_data["total_executions"].to_s, "text-crystal"
            render_metric_item "Avg Pattern Score", "#{profiler_data["avg_performance_score"].as(Float64).round(2)}", "text-performance"
            render_metric_item "Slowest Pattern", "#{profiler_data["slowest_pattern_time"].as(Float64).round(2)}ms", "text-accent"
            render_metric_item "Most Frequent", profiler_data["most_frequent_count"].to_s, "text-muted-foreground"
          end
        end
      end

      private def render_n_plus_one_analysis_card
        n_plus_one_data = @data_provider.collect_n_plus_one_data

        render_metric_card "N+1 Analysis", "git-branch" do
          if n_plus_one_data["issues"].as(Array).empty?
            render_empty_state("check", "No N+1 patterns detected", nil)
          else
            div class: "metric-list" do
              render_metric_item "Total Issues", n_plus_one_data["total_issues"].to_s, "text-primary"
              render_metric_item "Critical", n_plus_one_data["critical_count"].to_s, "text-destructive"
              render_metric_item "High", n_plus_one_data["high_count"].to_s, "text-accent"
              render_metric_item "Medium", n_plus_one_data["medium_count"].to_s, "text-crystal"
              render_metric_item "Low", n_plus_one_data["low_count"].to_s, "text-muted-foreground"
            end
          end
        end
      end

      private def render_slow_queries_table
        slow_queries = @data_provider.collect_slow_queries_data

        render_metric_card "Recent Slow Queries", "clock" do
          if slow_queries.empty?
            render_empty_state("check", "No slow queries detected!", "All queries are performing well.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Execution Time"
                    th "Query"
                    th "Normalized Pattern"
                    th "Rows"
                    th "Status"
                    th "Timestamp"
                  end
                end
                tbody do
                  slow_queries.each do |query|
                    query_hash = query.as(Hash)
                    execution_time = query_hash["execution_time_ms"].as(Float64)
                    severity_class = case execution_time
                                     when 0..100    then "text-performance"
                                     when 100..500  then "text-crystal"
                                     when 500..1000 then "text-accent"
                                     else                "text-destructive"
                                     end

                    tr do
                      td class: severity_class do
                        text "#{execution_time.round(2)}ms"
                      end
                      td do
                        pre class: "sql-query" do
                          text query_hash["sql"].as(String)
                        end
                      end
                      td do
                        code query_hash["normalized_sql"].as(String)
                      end
                      td do
                        text query_hash["rows_affected"].to_s
                      end
                      td do
                        error = query_hash["error"].as(String)
                        if error == "None"
                          span class: "badge badge-default" do
                            text "SUCCESS"
                          end
                        else
                          span class: "badge badge-destructive" do
                            text "ERROR"
                            div class: "tooltip" do
                              text error
                            end
                          end
                        end
                      end
                      td class: "text-muted-foreground" do
                        small query_hash["timestamp"].to_s
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_query_patterns_table
        query_patterns = @data_provider.collect_query_patterns_data

        render_metric_card "Query Patterns Analysis", "list" do
          if query_patterns.empty?
            render_empty_state("info", "No query patterns recorded", "Query patterns will appear here as queries are executed.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Pattern"
                    th "Executions"
                    th "Avg Time"
                    th "Performance Score"
                  end
                end
                tbody do
                  query_patterns.each do |pattern|
                    pattern_hash = pattern.as(Hash)
                    performance_score = pattern_hash["performance_score"].as(Float64)

                    score_class = case performance_score
                                  when 80.0..100.0 then "text-performance"
                                  when 60.0..79.9  then "text-crystal"
                                  when 40.0..59.9  then "text-accent"
                                  else                  "text-destructive"
                                  end

                    tr do
                      td do
                        code pattern_hash["normalized_sql"].as(String)[0..60] + (pattern_hash["normalized_sql"].as(String).size > 60 ? "..." : "")
                      end
                      td do
                        text pattern_hash["execution_count"].to_s
                      end
                      td do
                        text "#{pattern_hash["avg_time_ms"].as(Float64).round(2)}ms"
                      end
                      td class: score_class do
                        text performance_score.round(2).to_s
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_routes_tab
        div id: "routes", class: "tab-pane" do
          routes = @data_provider.collect_routes_data

          if routes.empty?
            render_empty_state("info", "No routes found", "Routes information requires router.routes method.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Method"
                    th "Path"
                    th "Handler"
                    th "Description"
                  end
                end
                tbody do
                  routes.each do |route|
                    route_hash = route.as(Hash)
                    next if route_hash["method"].downcase == "options" || route_hash["method"].downcase == "head"
                    method = route_hash["method"].as(String)
                    next if method.downcase == "options" || method.downcase == "head"
                    method_class = case method
                                   when "GET"          then "text-performance"
                                   when "POST"         then "text-accent"
                                   when "PUT", "PATCH" then "text-crystal"
                                   when "DELETE"       then "badge-destructive"
                                   else                     "badge-outline"
                                   end

                    tr do
                      td do
                        span class: "badge #{method_class}", style: method_class.starts_with?("text-") ? "background: hsl(var(--#{method_class.split("-")[1]}) / 0.2);" : "" do
                          text method
                        end
                      end
                      td do
                        code route_hash["path"]
                      end
                      td route_hash["handler"]
                      td class: "text-muted-foreground" do
                        text route_hash["description"]
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_app_status_card
        data = @data_provider.collect_app_status_data

        render_metric_card "Application Status", "monitor" do
          div class: "metric-list" do
            render_metric_item "Uptime", data["uptime_human"].to_s, "text-crystal"
            render_metric_item "Memory Usage", "#{data["memory_usage_mb"]} MB", "text-crystal"
            render_metric_item "Total Requests", data["total_requests"].to_s, "text-primary"
            render_metric_item "Error Rate", "#{data["error_rate"]}%",
              data["error_rate"].as(Float64) > 5.0 ? "text-muted-foreground" : "text-performance"
            render_metric_item "CPU Usage", "#{data["cpu_usage"].as(Float64).round(1)}%", "text-accent"
          end
        end
      end

      private def render_performance_card
        data = @data_provider.collect_performance_data

        render_metric_card "Performance Metrics", "zap" do
          div class: "metric-list" do
            render_metric_item "Avg Response Time", "#{data["avg_response_time_ms"]} ms", "text-crystal"
            render_metric_item "P95 Response Time", "#{data["p95_response_time_ms"]} ms", "text-accent"
            render_metric_item "P99 Response Time", "#{data["p99_response_time_ms"]} ms", "text-muted-foreground"
            render_metric_item "Requests/Second", data["requests_per_second"].as(Float64).round(2).to_s, "text-performance"
            render_metric_item "Peak Memory", "#{data["peak_memory_usage_mb"]} MB", "text-crystal"
          end
        end
      end

      private def render_cache_card
        data = @data_provider.collect_cache_data
        hit_rate = data["hit_rate"].as(Float64)

        render_metric_card "Cache Metrics", "database" do
          div class: "metric-list" do
            render_metric_item "Hit Rate", "#{hit_rate}%", "text-muted-foreground"
            render_metric_item "Total Operations", data["total_operations"].to_s, "text-primary"
            render_metric_item "GET Operations", data["get_operations"].to_s, "text-crystal"
            render_metric_item "SET Operations", data["set_operations"].to_s, "text-accent"
            render_metric_item "Avg Processing Time", "#{data["avg_processing_time_ms"]} ms", "text-muted-foreground"
            render_metric_item "Data Written", "#{data["total_data_written_mb"]} MB", "text-crystal"
          end
        end
      end

      private def render_database_card
        data = @data_provider.collect_database_data

        render_metric_card "Database Info", "database" do
          div class: "metric-list" do
            render_metric_item "Total Queries", data["total_queries"].to_s, "text-primary"
            render_metric_item "Slow Queries", "#{data["slow_queries"]} (#{data["slow_query_rate"].as(Float64).round(2)}%)",
              data["slow_query_rate"].as(Float64) > 5.0 ? "text-destructive" : "text-crystal"
            render_metric_item "Very Slow Queries", data["very_slow_queries"].to_s, "text-destructive"
            render_metric_item "Error Queries", "#{data["error_queries"]} (#{data["error_rate"].as(Float64).round(2)}%)",
              data["error_rate"].as(Float64) > 1.0 ? "text-destructive" : "text-crystal"
            render_metric_item "Avg Query Time", "#{data["avg_query_time"].as(Float64).round(2)}ms", "text-crystal"
            render_metric_item "Max Query Time", "#{data["max_query_time"].as(Float64).round(2)}ms", "text-accent"
            render_metric_item "Queries/Second", data["queries_per_second"].as(Float64).round(2).to_s, "text-performance"
            render_metric_item "N+1 Patterns", "#{data["n_plus_one_patterns"]} (#{data["critical_n_plus_one"]} critical)",
              data["critical_n_plus_one"].as(Int32) > 0 ? "text-destructive" : "text-crystal"
            render_metric_item "Health Score", "#{data["database_health_score"]}/100",
              data["database_health_score"].as(Int32) > 80 ? "text-performance" : "text-destructive"
          end
        end
      end

      private def render_component_card
        data = @data_provider.collect_component_data

        render_metric_card "Component Lifecycle", "layers" do
          div class: "metric-list" do
            render_metric_item "Total Components", data["total_components"].to_s, "text-primary"
            render_metric_item "Mount Events", data["mount_events"].to_s, "text-performance"
            render_metric_item "Unmount Events", data["unmount_events"].to_s, "text-accent"
            render_metric_item "Refresh Events", data["refresh_events"].to_s, "text-crystal"
            render_metric_item "Avg Component Age", "#{data["avg_component_age_seconds"].as(Float64).round(1)}s", "text-muted-foreground"
          end
        end
      end

      private def render_system_card
        data = @data_provider.collect_system_data

        render_metric_card "System Information", "settings" do
          div class: "metric-list" do
            render_metric_item "Crystal Version", data["crystal_version"].to_s, "text-primary"
            render_metric_item "Environment", data["environment"].to_s, "text-crystal"
            render_metric_item "Process ID", data["process_id"].to_s, "text-muted-foreground"
            render_metric_item "GC Heap Size", "#{data["gc_heap_size_mb"]} MB", "text-accent"
            render_metric_item "GC Free Bytes", "#{data["gc_free_bytes_mb"]} MB", "text-performance"
            render_metric_item "GC Total Bytes", "#{data["gc_total_bytes_mb"]} MB", "text-crystal"
          end
        end
      end

      private def render_test_results_card
        data = @data_provider.collect_test_data
        coverage = data["coverage_percent"].as(Float64)

        div class: "card test-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "flask-round"
              text "Test Results"
            end
          end
          div class: "card-content" do
            div class: "test-metrics" do
              div class: "test-metric" do
                para class: "test-metric-label" do
                  text "Last Run"
                end
                para class: "test-metric-value" do
                  text data["last_run"].to_s
                end
              end
              div class: "test-metric" do
                para class: "test-metric-label" do
                  text "Code Coverage"
                end
                para class: "test-metric-value" do
                  text "#{coverage}%"
                end
                div class: "progress" do
                  div class: "progress-bar", style: "width: #{coverage}%" do
                    text "#{coverage}%"
                  end
                end
              end
              div class: "test-metric" do
                para class: "test-metric-label" do
                  text "Total Tests"
                end
                para class: "test-metric-value" do
                  text data["total_tests"].to_s
                end
              end
              div class: "test-metric" do
                para class: "test-metric-label" do
                  text "Failed Tests"
                end
                para class: "test-metric-value" do
                  text data["failed_tests"].to_s
                end
              end
              div class: "test-metric" do
                para class: "test-metric-label" do
                  text "Suite Time"
                end
                para class: "test-metric-value" do
                  text "#{data["test_suite_time_seconds"]}s"
                end
              end
            end
          end
        end
      end

      private def render_cache_tab
        div id: "cache", class: "tab-pane" do
          # Cache Overview Cards
          div class: "grid grid-cols-3 mb-6" do
            render_cache_overview_cards
            render_cache_operations_card
            render_cache_performance_card
          end
          # Detailed Cache Tables
          render_cache_breakdown_table
          render_recent_cache_operations_table
        end
      end

      private def render_components_tab
        div id: "components", class: "tab-pane" do
          # Component Overview Cards
          div class: "grid grid-cols-3 mb-6" do
            render_component_overview_cards
            render_component_events_card
            render_component_performance_card
          end
          # Detailed Component Tables
          render_recent_component_events_table
        end
      end

      private def render_cache_overview_cards
        data = @data_provider.collect_cache_data

        render_metric_card "Cache Overview", "hard-drive" do
          div class: "metric-list" do
            render_metric_item "Total Operations", data["total_operations"].to_s, "text-primary"
            render_metric_item "Hit Rate", "#{data["hit_rate"]}%",
              data["hit_rate"].as(Float64) > 80.0 ? "text-performance" : "text-accent"
            render_metric_item "Error Rate", "#{data["error_rate"]}%",
              data["error_rate"].as(Float64) > 5.0 ? "text-destructive" : "text-muted-foreground"
            render_metric_item "Avg Processing Time", "#{data["avg_processing_time_ms"]} ms", "text-crystal"
          end
        end
      end

      private def render_cache_operations_card
        data = @data_provider.collect_cache_data

        render_metric_card "Cache Operations", "activity" do
          div class: "metric-list" do
            render_metric_item "GET Operations", data["get_operations"].to_s, "text-primary"
            render_metric_item "SET Operations", data["set_operations"].to_s, "text-crystal"
            render_metric_item "DELETE Operations", data["delete_operations"].to_s, "text-accent"
            render_metric_item "Data Written", "#{data["total_data_written_mb"]} MB", "text-muted-foreground"
          end
        end
      end

      private def render_cache_performance_card
        breakdown = @data_provider.collect_cache_breakdown_data

        render_metric_card "Cache Performance", "zap" do
          if breakdown.empty?
            render_empty_state("info", "No cache operations recorded", "Cache operations will appear here as they are executed.")
          else
            div class: "metric-list" do
              breakdown.each do |operation, stats|
                next if stats["count"].to_i == 0
                render_metric_item "#{operation.upcase} Count", stats["count"].to_i.to_s, "text-primary"
                render_metric_item "#{operation.upcase} Avg Time", "#{stats["avg_time"].round(2)} ms", "text-crystal"
                render_metric_item "#{operation.upcase} Error Rate", "#{stats["error_rate"].round(2)}%",
                  stats["error_rate"] > 5.0 ? "text-destructive" : "text-muted-foreground"
                break # Only show first operation for space
              end
            end
          end
        end
      end

      private def render_cache_breakdown_table
        breakdown = @data_provider.collect_cache_breakdown_data

        render_metric_card "Cache Operation Breakdown", "list" do
          if breakdown.empty?
            render_empty_state("info", "No cache operations recorded", "Cache operations will appear here as they are executed.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Operation"
                    th "Count"
                    th "Avg Time"
                    th "Error Rate"
                    th "Hit Rate"
                    th "Data Written"
                  end
                end
                tbody do
                  breakdown.each do |operation, stats|
                    next if stats["count"].to_i == 0
                    tr do
                      td do
                        span class: "badge badge-outline" do
                          text operation.upcase
                        end
                      end
                      td stats["count"].to_i.to_s
                      td "#{stats["avg_time"].round(2)}ms"
                      td do
                        error_rate = stats["error_rate"]
                        span class: "badge #{error_rate > 5.0 ? "badge-destructive" : "badge-outline"}" do
                          text "#{error_rate.round(2)}%"
                        end
                      end
                      td do
                        if hit_rate = stats["hit_rate"]?
                          span class: "badge #{hit_rate > 80.0 ? "badge-default" : "badge-outline"}" do
                            text "#{hit_rate.round(2)}%"
                          end
                        else
                          text "N/A"
                        end
                      end
                      td do
                        if data_written = stats["total_data_written"]?
                          text "#{(data_written / 1024.0 / 1024.0).round(2)} MB"
                        else
                          text "N/A"
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_recent_cache_operations_table
        recent_operations = @data_provider.collect_recent_cache_operations

        render_metric_card "Recent Cache Operations", "clock" do
          if recent_operations.empty?
            render_empty_state("info", "No recent cache operations", "Cache operations will appear here as they are executed.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Timestamp"
                    th "Operation"
                    th "Key"
                    th "Store"
                    th "Hit/Miss"
                    th "Time"
                    th "Status"
                  end
                end
                tbody do
                  recent_operations.each do |op|
                    op_hash = op.as(Hash)
                    tr do
                      td class: "text-muted-foreground" do
                        small op_hash["timestamp"].to_s
                      end
                      td do
                        span class: "badge badge-outline" do
                          text op_hash["operation"].as(String).upcase
                        end
                      end
                      td do
                        code op_hash["key"].as(String)[0..30] + (op_hash["key"].as(String).size > 30 ? "..." : "")
                      end
                      td op_hash["store_type"].to_s
                      td do
                        hit = op_hash["hit"].as(String)
                        if hit == "true"
                          span class: "badge badge-default" do
                            text "HIT"
                          end
                        elsif hit == "false"
                          span class: "badge badge-outline" do
                            text "MISS"
                          end
                        else
                          text "N/A"
                        end
                      end
                      td "#{op_hash["processing_time_ms"]}ms"
                      td do
                        successful = op_hash["successful"].as(String)
                        span class: "badge #{successful == "true" ? "badge-default" : "badge-destructive"}" do
                          text successful == "true" ? "SUCCESS" : "ERROR"
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def render_component_overview_cards
        data = @data_provider.collect_component_data

        render_metric_card "Component Overview", "layers" do
          div class: "metric-list" do
            render_metric_item "Total Components", data["total_components"].to_s, "text-primary"
            render_metric_item "Mount Events", data["mount_events"].to_s, "text-performance"
            render_metric_item "Unmount Events", data["unmount_events"].to_s, "text-accent"
            render_metric_item "Refresh Events", data["refresh_events"].to_s, "text-crystal"
          end
        end
      end

      private def render_component_events_card
        data = @data_provider.collect_component_data

        render_metric_card "Component Events", "activity" do
          div class: "metric-list" do
            render_metric_item "Avg Component Age", "#{data["avg_component_age_seconds"].as(Float64).round(1)}s", "text-muted-foreground"
            render_metric_item "Total Events", (data["mount_events"].as(Int32) + data["unmount_events"].as(Int32) + data["refresh_events"].as(Int32)).to_s, "text-primary"
            render_metric_item "Event Rate", calculate_component_event_rate.to_s, "text-crystal"
          end
        end
      end

      private def render_component_performance_card
        recent_events = @data_provider.collect_recent_component_events(10)

        render_metric_card "Component Performance", "zap" do
          if recent_events.empty?
            render_empty_state("info", "No component events recorded", "Component events will appear here as they occur.")
          else
            div class: "metric-list" do
              avg_processing_time = recent_events.compact_map { |event| event["processing_time_ms"].as(String) }.select { |time_str| time_str != "N/A" }.sum(&.to_f) / recent_events.size
              render_metric_item "Avg Processing Time", "#{avg_processing_time.round(2)} ms", "text-crystal"
              render_metric_item "Recent Events", recent_events.size.to_s, "text-primary"
            end
          end
        end
      end

      private def render_recent_component_events_table
        recent_events = @data_provider.collect_recent_component_events

        render_metric_card "Recent Component Events", "clock" do
          if recent_events.empty?
            render_empty_state("info", "No component events recorded", "Component events will appear here as they occur.")
          else
            div class: "table-container" do
              table class: "table" do
                thead do
                  tr do
                    th "Timestamp"
                    th "Component"
                    th "Type"
                    th "Event"
                    th "Processing Time"
                    th "Memory Delta"
                    th "Age"
                  end
                end
                tbody do
                  recent_events.each do |event|
                    event_hash = event.as(Hash)
                    tr do
                      td class: "text-muted-foreground" do
                        small event_hash["timestamp"]
                      end
                      td do
                        code event_hash["component_id"].as(String)[0..20] + (event_hash["component_id"].as(String).size > 20 ? "..." : "")
                      end
                      td event_hash["component_type"]
                      td do
                        event_type = event_hash["event"].as(String)
                        span class: "badge #{event_type == "mount" ? "badge-default" : event_type == "unmount" ? "badge-destructive" : "badge-outline"}" do
                          text event_type.upcase
                        end
                      end
                      td event_hash["processing_time_ms"]
                      td event_hash["memory_delta_mb"]
                      td event_hash["age_at_event_seconds"]
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def calculate_component_event_rate : String
        data = @data_provider.collect_component_data
        total_events = data["mount_events"].as(Int32) + data["unmount_events"].as(Int32) + data["refresh_events"].as(Int32)
        uptime = Time.utc - @start_time

        return "0/s" if uptime.total_seconds <= 0
        rate = total_events.to_f / uptime.total_seconds
        "#{rate.round(2)}/s"
      end

      private def render_metric_item(label : String, value : String, value_class : String = "")
        div class: "metric-item" do
          span class: "metric-label" do
            text label
          end
          span class: "metric-value #{value_class}" do
            text value
          end
        end
      end

      private def render_metric_card(title : String, icon : String, &block)
        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": icon
              text title
            end
          end
          div class: "card-content" do
            block.call
          end
        end
      end

      private def render_empty_state(icon : String, title : String, message : String?)
        div(class: "empty-state") do
          i("data-lucide": icon)
          h4 { text(title) }
          para class: "header-text" do
            text message
          end
        end
      end

      private def render_scripts
        script do
          raw dashboard_scripts
        end
      end

      private def custom_styles
        <<-CSS
        /* ===== Theme Variables ===== */
        :root {
          /* Spacing Scale */
          --space-1: 0.25rem;
          --space-2: 0.5rem;
          --space-3: 0.75rem;
          --space-4: 1rem;
          --space-5: 1.25rem;
          --space-6: 1.5rem;
          --space-8: 2rem;
          --space-10: 2.5rem;
          --space-12: 3rem;

          /* Animation */
          --transition-fast: 150ms ease;
          --transition-normal: 250ms ease;
          --transition-slow: 350ms ease;

          /* Sidebar */
          --sidebar-width: 240px;
          --sidebar-collapsed-width: 60px;
        }

        /* ===== Dark Theme (Default) ===== */
        :root, [data-theme="dark"] {
          /* Base Colors - Rich dark with blue undertones */
          --background: 230 25% 7%;
          --foreground: 210 20% 95%;
          --card: 230 25% 10%;
          --card-foreground: 210 20% 95%;
          --popover: 230 25% 10%;
          --popover-foreground: 210 20% 95%;
          --primary: 210 100% 60%;
          --primary-foreground: 230 25% 7%;
          --secondary: 230 20% 16%;
          --secondary-foreground: 210 20% 90%;
          --muted: 230 20% 18%;
          --muted-foreground: 215 15% 60%;
          --accent: 230 25% 20%;
          --accent-foreground: 210 20% 95%;
          --destructive: 0 85% 60%;
          --destructive-foreground: 210 20% 98%;
          --border: 230 20% 20%;
          --input: 230 20% 18%;
          --ring: 210 100% 60%;

          /* Semantic Status Colors - Vibrant for dark mode */
          --status-healthy: 152 76% 50%;
          --status-warning: 38 95% 55%;
          --status-critical: 0 85% 60%;

          /* Azu Theme Colors - Crystal cyan accent */
          --crystal: 190 95% 55%;
          --performance: 152 76% 50%;
          --accent-azu: 38 95% 55%;

          /* Gradients & Effects */
          --gradient-primary: linear-gradient(135deg, hsl(var(--performance)), hsl(var(--crystal)));
          --gradient-card: linear-gradient(145deg, hsl(var(--card)), hsl(230 25% 12%));
          --gradient-sidebar: linear-gradient(180deg, hsl(230 25% 9%), hsl(var(--background)));
          --shadow-glow: 0 0 40px hsl(var(--crystal) / 0.2);
          --shadow-card: 0 1px 3px 0 rgb(0 0 0 / 0.3), 0 1px 2px -1px rgb(0 0 0 / 0.2);
          --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.3), 0 4px 6px -4px rgb(0 0 0 / 0.2);

          color-scheme: dark;
        }

        /* ===== Light Theme ===== */
        [data-theme="light"] {
          /* Base Colors - Clean light with subtle warmth */
          --background: 210 20% 98%;
          --foreground: 230 25% 10%;
          --card: 0 0% 100%;
          --card-foreground: 230 25% 10%;
          --popover: 0 0% 100%;
          --popover-foreground: 230 25% 10%;
          --primary: 210 100% 45%;
          --primary-foreground: 0 0% 100%;
          --secondary: 210 15% 92%;
          --secondary-foreground: 230 25% 15%;
          --muted: 210 15% 94%;
          --muted-foreground: 215 15% 45%;
          --accent: 210 20% 93%;
          --accent-foreground: 230 25% 10%;
          --destructive: 0 75% 50%;
          --destructive-foreground: 0 0% 100%;
          --border: 210 15% 88%;
          --input: 210 15% 92%;
          --ring: 210 100% 45%;

          /* Semantic Status Colors - Slightly muted for light mode */
          --status-healthy: 152 65% 40%;
          --status-warning: 38 92% 45%;
          --status-critical: 0 75% 50%;

          /* Azu Theme Colors */
          --crystal: 190 85% 42%;
          --performance: 152 65% 40%;
          --accent-azu: 38 92% 45%;

          /* Gradients & Effects */
          --gradient-primary: linear-gradient(135deg, hsl(var(--performance)), hsl(var(--crystal)));
          --gradient-card: linear-gradient(145deg, hsl(var(--card)), hsl(210 15% 97%));
          --gradient-sidebar: linear-gradient(180deg, hsl(0 0% 100%), hsl(210 20% 97%));
          --shadow-glow: 0 0 40px hsl(var(--crystal) / 0.15);
          --shadow-card: 0 1px 3px 0 rgb(0 0 0 / 0.08), 0 1px 2px -1px rgb(0 0 0 / 0.05);
          --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.08), 0 4px 6px -4px rgb(0 0 0 / 0.04);

          color-scheme: light;
        }

        * {
          margin: 0;
          padding: 0;
          box-sizing: border-box;
        }

        body {
          font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          background: hsl(var(--background));
          color: hsl(var(--foreground));
          line-height: 1.6;
          min-height: 100vh;
        }

        /* ===== App Layout ===== */
        .app-layout {
          display: flex;
          min-height: 100vh;
        }

        /* ===== Sidebar ===== */
        .sidebar {
          width: var(--sidebar-width);
          background: var(--gradient-sidebar);
          border-right: 1px solid hsl(var(--border));
          display: flex;
          flex-direction: column;
          position: fixed;
          top: 0;
          left: 0;
          height: 100vh;
          z-index: 50;
          transition: width var(--transition-normal);
        }

        .sidebar-header {
          padding: var(--space-4) var(--space-4);
          border-bottom: 1px solid hsl(var(--border) / 0.5);
        }

        .sidebar-brand {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-size: 1rem;
          font-weight: 700;
          color: hsl(var(--foreground));
          text-decoration: none;
        }

        .sidebar-brand svg {
          color: hsl(var(--crystal));
        }

        .sidebar-nav {
          flex: 1;
          padding: var(--space-4) var(--space-2);
          overflow-y: auto;
        }

        .nav-section {
          margin-bottom: var(--space-4);
        }

        .nav-section-title {
          font-size: 0.75rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: hsl(var(--muted-foreground));
          padding: var(--space-2) var(--space-3);
          margin-bottom: var(--space-1);
        }

        .nav-item {
          display: flex;
          align-items: center;
          gap: var(--space-3);
          padding: var(--space-2) var(--space-3);
          border-radius: 0.375rem;
          color: hsl(var(--muted-foreground));
          text-decoration: none;
          font-size: 0.875rem;
          font-weight: 500;
          cursor: pointer;
          transition: all var(--transition-fast);
          border: none;
          background: transparent;
          width: 100%;
          text-align: left;
        }

        .nav-item:hover {
          background: hsl(var(--accent));
          color: hsl(var(--foreground));
        }

        .nav-item.active {
          background: hsl(var(--accent));
          color: hsl(var(--foreground));
        }

        .nav-item-badge {
          margin-left: auto;
          font-size: 0.75rem;
          padding: 0.125rem 0.5rem;
          border-radius: 9999px;
          font-weight: 600;
        }

        .nav-item-badge.warning {
          background: hsl(var(--status-warning) / 0.2);
          color: hsl(var(--status-warning));
        }

        .nav-item-badge.error {
          background: hsl(var(--status-critical) / 0.2);
          color: hsl(var(--status-critical));
        }

        .nav-item-badge.default {
          background: hsl(var(--muted));
          color: hsl(var(--muted-foreground));
        }

        .sidebar-footer {
          padding: var(--space-3) var(--space-4);
          border-top: 1px solid hsl(var(--border) / 0.5);
          display: flex;
          flex-direction: column;
          gap: var(--space-3);
        }

        /* Theme Toggle */
        .theme-toggle-container {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: var(--space-2);
        }

        .theme-toggle-label {
          font-size: 0.75rem;
          font-weight: 500;
          color: hsl(var(--muted-foreground));
          text-transform: uppercase;
          letter-spacing: 0.05em;
        }

        .theme-toggle-buttons {
          display: flex;
          gap: 2px;
          background: hsl(var(--muted) / 0.5);
          padding: 3px;
          border-radius: 8px;
        }

        .theme-btn {
          display: flex;
          align-items: center;
          justify-content: center;
          width: 28px;
          height: 28px;
          border: none;
          background: transparent;
          color: hsl(var(--muted-foreground));
          border-radius: 6px;
          cursor: pointer;
          transition: all var(--transition-fast);
        }

        .theme-btn:hover {
          color: hsl(var(--foreground));
          background: hsl(var(--accent));
        }

        .theme-btn.active {
          background: hsl(var(--card));
          color: hsl(var(--crystal));
          box-shadow: var(--shadow-card);
        }

        .theme-btn svg,
        .theme-btn i {
          width: 14px;
          height: 14px;
        }

        .status-indicator {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
        }

        .status-dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: hsl(var(--status-healthy));
          animation: pulse 2s infinite;
        }

        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.5; }
        }

        /* ===== Main Content ===== */
        .main-content {
          flex: 1;
          margin-left: var(--sidebar-width);
          display: flex;
          flex-direction: column;
          min-height: 100vh;
        }

        /* ===== Top Bar ===== */
        .top-bar {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-3) var(--space-6);
          border-bottom: 1px solid hsl(var(--border));
          background: hsl(var(--card));
          position: sticky;
          top: 0;
          z-index: 40;
        }

        .top-bar-left {
          display: flex;
          align-items: center;
          gap: var(--space-4);
        }

        .top-bar-right {
          display: flex;
          align-items: center;
          gap: var(--space-2);
        }

        /* ===== Health Score Ring ===== */
        .health-score {
          display: flex;
          align-items: center;
          gap: var(--space-3);
        }

        .health-ring {
          position: relative;
          width: 48px;
          height: 48px;
        }

        .health-ring svg {
          transform: rotate(-90deg);
        }

        .health-ring-bg {
          fill: none;
          stroke: hsl(var(--muted));
          stroke-width: 4;
        }

        .health-ring-progress {
          fill: none;
          stroke-width: 4;
          stroke-linecap: round;
          transition: stroke-dashoffset var(--transition-slow);
        }

        .health-ring-progress.healthy { stroke: hsl(var(--status-healthy)); }
        .health-ring-progress.warning { stroke: hsl(var(--status-warning)); }
        .health-ring-progress.critical { stroke: hsl(var(--status-critical)); }

        .health-value {
          position: absolute;
          top: 50%;
          left: 50%;
          transform: translate(-50%, -50%);
          font-size: 0.875rem;
          font-weight: 700;
          font-family: 'JetBrains Mono', monospace;
        }

        .health-label {
          font-size: 0.875rem;
          font-weight: 500;
        }

        .health-label.healthy { color: hsl(var(--status-healthy)); }
        .health-label.warning { color: hsl(var(--status-warning)); }
        .health-label.critical { color: hsl(var(--status-critical)); }

        /* ===== Quick Stats Bar ===== */
        .quick-stats {
          display: flex;
          gap: var(--space-6);
          padding: 0 var(--space-4);
        }

        .quick-stat {
          display: flex;
          flex-direction: column;
          gap: 0;
        }

        .quick-stat-label {
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
          font-weight: 500;
        }

        .quick-stat-value {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-size: 0.875rem;
          font-weight: 600;
          font-family: 'JetBrains Mono', monospace;
        }

        .trend-up { color: hsl(var(--status-healthy)); }
        .trend-down { color: hsl(var(--status-critical)); }
        .trend-neutral { color: hsl(var(--muted-foreground)); }

        /* ===== Buttons ===== */
        .btn {
          display: inline-flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-2) var(--space-3);
          border: none;
          border-radius: 0.375rem;
          font-weight: 500;
          font-size: 0.875rem;
          cursor: pointer;
          transition: all var(--transition-fast);
        }

        .btn-ghost {
          background: transparent;
          color: hsl(var(--muted-foreground));
        }

        .btn-ghost:hover {
          background: hsl(var(--accent));
          color: hsl(var(--foreground));
        }

        .btn-outline {
          background: transparent;
          color: hsl(var(--foreground));
          border: 1px solid hsl(var(--border));
        }

        .btn-outline:hover {
          background: hsl(var(--accent));
        }

        .btn-primary {
          background: hsl(var(--primary));
          color: hsl(var(--primary-foreground));
        }

        .btn-primary:hover {
          background: hsl(var(--primary) / 0.9);
        }

        .btn-icon {
          padding: var(--space-2);
        }

        /* ===== Alert Banner ===== */
        .alert-banner {
          display: flex;
          align-items: center;
          gap: var(--space-3);
          padding: var(--space-3) var(--space-6);
          background: hsl(var(--status-critical) / 0.1);
          border-bottom: 1px solid hsl(var(--status-critical) / 0.3);
        }

        .alert-banner.warning {
          background: hsl(var(--status-warning) / 0.1);
          border-bottom-color: hsl(var(--status-warning) / 0.3);
        }

        .alert-icon {
          color: hsl(var(--status-critical));
          flex-shrink: 0;
        }

        .alert-banner.warning .alert-icon {
          color: hsl(var(--status-warning));
        }

        .alert-content {
          flex: 1;
          font-size: 0.875rem;
        }

        .alert-title {
          font-weight: 600;
          margin-bottom: var(--space-1);
        }

        .alert-list {
          list-style: none;
          color: hsl(var(--muted-foreground));
        }

        .alert-action {
          color: hsl(var(--crystal));
          font-weight: 500;
          text-decoration: none;
          cursor: pointer;
        }

        .alert-action:hover {
          text-decoration: underline;
        }

        /* ===== Content Area ===== */
        .content-area {
          flex: 1;
          padding: var(--space-6);
          overflow-y: auto;
        }

        .section {
          display: none;
        }

        .section.active {
          display: block;
        }

        .section-header {
          margin-bottom: var(--space-6);
        }

        .section-title {
          font-size: 1.5rem;
          font-weight: 700;
          margin-bottom: var(--space-2);
        }

        .section-description {
          color: hsl(var(--muted-foreground));
          font-size: 0.875rem;
        }

        /* ===== Insights Panel ===== */
        .insights-panel {
          background: hsl(var(--card));
          border: 1px solid hsl(var(--border));
          border-radius: 0.5rem;
          margin-bottom: var(--space-6);
          overflow: hidden;
        }

        .insights-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-3) var(--space-4);
          border-bottom: 1px solid hsl(var(--border));
          background: hsl(var(--muted) / 0.3);
        }

        .insights-title {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-weight: 600;
          font-size: 0.875rem;
        }

        .insight-item {
          display: flex;
          gap: var(--space-3);
          padding: var(--space-3) var(--space-4);
          border-bottom: 1px solid hsl(var(--border) / 0.5);
          transition: background var(--transition-fast);
        }

        .insight-item:last-child {
          border-bottom: none;
        }

        .insight-item:hover {
          background: hsl(var(--muted) / 0.3);
        }

        .insight-severity {
          flex-shrink: 0;
          width: 8px;
          height: 8px;
          border-radius: 50%;
          margin-top: 6px;
        }

        .insight-severity.critical { background: hsl(var(--status-critical)); }
        .insight-severity.warning { background: hsl(var(--status-warning)); }
        .insight-severity.info { background: hsl(var(--crystal)); }

        .insight-content {
          flex: 1;
        }

        .insight-message {
          font-size: 0.875rem;
          font-weight: 500;
          margin-bottom: var(--space-1);
        }

        .insight-detail {
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
        }

        .insight-action {
          color: hsl(var(--crystal));
          font-size: 0.75rem;
          cursor: pointer;
        }

        .insight-action:hover {
          text-decoration: underline;
        }

        /* ===== Grid Layout ===== */
        .grid {
          display: grid;
          gap: var(--space-6);
        }

        .grid-cols-2 {
          grid-template-columns: repeat(2, 1fr);
        }

        .grid-cols-3 {
          grid-template-columns: repeat(3, 1fr);
        }

        .grid-cols-4 {
          grid-template-columns: repeat(4, 1fr);
        }

        @media (max-width: 1200px) {
          .grid-cols-4 { grid-template-columns: repeat(2, 1fr); }
          .grid-cols-3 { grid-template-columns: repeat(2, 1fr); }
        }

        @media (max-width: 768px) {
          .grid-cols-4, .grid-cols-3, .grid-cols-2 {
            grid-template-columns: 1fr;
          }
          .sidebar {
            transform: translateX(-100%);
          }
          .sidebar.open {
            transform: translateX(0);
          }
          .main-content {
            margin-left: 0;
          }
        }

        .mb-4 { margin-bottom: var(--space-4); }
        .mb-6 { margin-bottom: var(--space-6); }

        /* ===== Metric Cards v2 ===== */
        .metric-card {
          background: hsl(var(--card));
          border: 1px solid hsl(var(--border));
          border-radius: 0.5rem;
          overflow: hidden;
          transition: all var(--transition-fast);
        }

        .metric-card:hover {
          border-color: hsl(var(--border) / 0.8);
          box-shadow: var(--shadow-lg);
        }

        .card-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-3) var(--space-4);
          border-bottom: 1px solid hsl(var(--border) / 0.5);
        }

        .card-title {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-size: 0.875rem;
          font-weight: 600;
          margin: 0;
        }

        .card-content {
          padding: var(--space-4);
        }

        /* Metric with Sparkline */
        .metric-with-sparkline {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: var(--space-4);
        }

        .metric-block {
          display: flex;
          flex-direction: column;
          gap: var(--space-1);
        }

        .metric-block-label {
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
          font-weight: 500;
        }

        .metric-block-value {
          font-size: 1.5rem;
          font-weight: 700;
          font-family: 'JetBrains Mono', monospace;
        }

        .metric-block-sub {
          display: flex;
          gap: var(--space-3);
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
        }

        .sparkline-container {
          height: 32px;
          margin: var(--space-2) 0;
        }

        .sparkline {
          width: 100%;
          height: 100%;
        }

        .sparkline-line {
          fill: none;
          stroke: hsl(var(--crystal));
          stroke-width: 1.5;
        }

        .sparkline-area {
          fill: hsl(var(--crystal) / 0.1);
        }

        /* Metric List (simplified for card) */
        .metric-list {
          display: flex;
          flex-direction: column;
          gap: var(--space-3);
        }

        .metric-item {
          display: flex;
          justify-content: space-between;
          align-items: center;
        }

        .metric-label {
          font-size: 0.875rem;
          color: hsl(var(--muted-foreground));
        }

        .metric-value {
          font-family: 'JetBrains Mono', monospace;
          font-size: 0.875rem;
          font-weight: 500;
          padding: var(--space-1) var(--space-2);
          border-radius: 0.25rem;
          background: hsl(var(--muted) / 0.3);
        }

        .metric-value.healthy {
          color: hsl(var(--status-healthy));
          background: hsl(var(--status-healthy) / 0.1);
        }
        .metric-value.warning {
          color: hsl(var(--status-warning));
          background: hsl(var(--status-warning) / 0.1);
        }
        .metric-value.critical {
          color: hsl(var(--status-critical));
          background: hsl(var(--status-critical) / 0.1);
        }

        /* Card Status Footer */
        .card-status {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-2) var(--space-4);
          background: hsl(var(--muted) / 0.2);
          font-size: 0.75rem;
        }

        .card-status-dot {
          width: 6px;
          height: 6px;
          border-radius: 50%;
        }

        .card-status-dot.healthy { background: hsl(var(--status-healthy)); }
        .card-status-dot.warning { background: hsl(var(--status-warning)); }
        .card-status-dot.critical { background: hsl(var(--status-critical)); }

        /* Text Colors */
        .text-crystal { color: hsl(var(--crystal)); }
        .text-performance { color: hsl(var(--performance)); }
        .text-primary { color: hsl(var(--primary)); }
        .text-accent { color: hsl(var(--accent-azu)); }
        .text-muted-foreground { color: hsl(var(--muted-foreground)); }
        .text-destructive { color: hsl(var(--status-critical)); }

        /* ===== Enhanced Tables ===== */
        .table-card {
          background: hsl(var(--card));
          border: 1px solid hsl(var(--border));
          border-radius: 0.5rem;
          overflow: hidden;
        }

        .table-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-3) var(--space-4);
          border-bottom: 1px solid hsl(var(--border));
        }

        .table-title {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-weight: 600;
          font-size: 0.875rem;
        }

        .table-search {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          padding: var(--space-2) var(--space-3);
          background: hsl(var(--muted));
          border-radius: 0.375rem;
          border: 1px solid transparent;
          transition: all var(--transition-fast);
        }

        .table-search:focus-within {
          border-color: hsl(var(--crystal));
          background: hsl(var(--background));
        }

        .table-search input {
          background: transparent;
          border: none;
          outline: none;
          color: hsl(var(--foreground));
          font-size: 0.875rem;
          width: 200px;
        }

        .table-search input::placeholder {
          color: hsl(var(--muted-foreground));
        }

        .table-container {
          overflow-x: auto;
        }

        .table {
          width: 100%;
          border-collapse: collapse;
        }

        .table th {
          text-align: left;
          padding: var(--space-3) var(--space-4);
          font-size: 0.75rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: hsl(var(--muted-foreground));
          background: hsl(var(--muted) / 0.3);
          border-bottom: 1px solid hsl(var(--border));
          cursor: pointer;
          user-select: none;
          transition: background var(--transition-fast);
        }

        .table th:hover {
          background: hsl(var(--muted) / 0.5);
        }

        .table th .sort-icon {
          margin-left: var(--space-1);
          opacity: 0.5;
        }

        .table th.sorted .sort-icon {
          opacity: 1;
        }

        .table td {
          padding: var(--space-3) var(--space-4);
          font-size: 0.875rem;
          border-bottom: 1px solid hsl(var(--border) / 0.5);
          vertical-align: top;
        }

        .table tr {
          transition: background var(--transition-fast);
        }

        .table tbody tr:hover {
          background: hsl(var(--muted) / 0.3);
        }

        .table code {
          font-family: 'JetBrains Mono', monospace;
          font-size: 0.75rem;
          background: hsl(var(--muted));
          padding: var(--space-1) var(--space-2);
          border-radius: 0.25rem;
        }

        .table-pagination {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-3) var(--space-4);
          border-top: 1px solid hsl(var(--border));
          font-size: 0.875rem;
          color: hsl(var(--muted-foreground));
        }

        .pagination-controls {
          display: flex;
          align-items: center;
          gap: var(--space-1);
        }

        .pagination-btn {
          padding: var(--space-1) var(--space-2);
          border: 1px solid hsl(var(--border));
          background: transparent;
          color: hsl(var(--foreground));
          border-radius: 0.25rem;
          cursor: pointer;
          transition: all var(--transition-fast);
        }

        .pagination-btn:hover {
          background: hsl(var(--accent));
        }

        .pagination-btn.active {
          background: hsl(var(--primary));
          color: hsl(var(--primary-foreground));
          border-color: hsl(var(--primary));
        }

        /* Expandable Row */
        .expandable-row {
          cursor: pointer;
        }

        .row-details {
          display: none;
          padding: var(--space-3) var(--space-4);
          background: hsl(var(--muted) / 0.2);
          border-bottom: 1px solid hsl(var(--border) / 0.5);
        }

        .row-details.open {
          display: block;
        }

        /* ===== Badges ===== */
        .badge {
          display: inline-flex;
          align-items: center;
          padding: var(--space-1) var(--space-2);
          border-radius: 9999px;
          font-size: 0.75rem;
          font-weight: 600;
          line-height: 1;
        }

        .badge-default {
          background: hsl(var(--primary));
          color: hsl(var(--primary-foreground));
        }

        .badge-outline {
          background: transparent;
          border: 1px solid hsl(var(--border));
          color: hsl(var(--foreground));
        }

        .badge-destructive {
          background: hsl(var(--status-critical));
          color: white;
        }

        .badge-warning {
          background: hsl(var(--status-warning));
          color: hsl(var(--primary-foreground));
        }

        .badge-success {
          background: hsl(var(--status-healthy));
          color: white;
        }

        .badge-method {
          font-family: 'JetBrains Mono', monospace;
          font-size: 0.7rem;
          padding: var(--space-1) var(--space-2);
        }

        .badge-method.get { background: hsl(var(--status-healthy) / 0.2); color: hsl(var(--status-healthy)); }
        .badge-method.post { background: hsl(var(--crystal) / 0.2); color: hsl(var(--crystal)); }
        .badge-method.put, .badge-method.patch { background: hsl(var(--status-warning) / 0.2); color: hsl(var(--status-warning)); }
        .badge-method.delete { background: hsl(var(--status-critical) / 0.2); color: hsl(var(--status-critical)); }

        /* ===== Empty State ===== */
        .empty-state {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: var(--space-12);
          text-align: center;
        }

        .empty-state svg {
          width: 48px;
          height: 48px;
          color: hsl(var(--muted-foreground));
          margin-bottom: var(--space-4);
        }

        .empty-state h4 {
          font-size: 1rem;
          font-weight: 600;
          margin-bottom: var(--space-2);
        }

        .empty-state p {
          font-size: 0.875rem;
          color: hsl(var(--muted-foreground));
        }

        /* ===== SQL Query Display ===== */
        .sql-query {
          font-family: 'JetBrains Mono', monospace;
          font-size: 0.75rem;
          background: hsl(var(--muted));
          padding: var(--space-2);
          border-radius: 0.375rem;
          white-space: pre-wrap;
          word-wrap: break-word;
          max-width: 400px;
          max-height: 150px;
          overflow-y: auto;
          border: 1px solid hsl(var(--border) / 0.3);
          margin: 0;
          line-height: 1.4;
        }

        /* ===== Progress Bar ===== */
        .progress {
          width: 100%;
          height: 6px;
          background: hsl(var(--muted));
          border-radius: 9999px;
          overflow: hidden;
        }

        .progress-bar {
          height: 100%;
          border-radius: 9999px;
          transition: width var(--transition-normal);
        }

        .progress-bar.healthy { background: hsl(var(--status-healthy)); }
        .progress-bar.warning { background: hsl(var(--status-warning)); }
        .progress-bar.critical { background: hsl(var(--status-critical)); }

        /* ===== Test Card ===== */
        .test-card {
          background: var(--gradient-primary);
          border: 1px solid hsl(var(--border) / 0.5);
        }

        .test-card .card-title {
          color: hsl(var(--primary-foreground));
        }

        .test-metrics {
          display: grid;
          grid-template-columns: repeat(5, 1fr);
          gap: var(--space-4);
        }

        @media (max-width: 768px) {
          .test-metrics {
            grid-template-columns: repeat(2, 1fr);
          }
        }

        .test-metric {
          display: flex;
          flex-direction: column;
          gap: var(--space-1);
        }

        .test-metric-label {
          font-size: 0.75rem;
          color: hsl(var(--primary-foreground) / 0.8);
        }

        .test-metric-value {
          font-size: 0.875rem;
          font-weight: 600;
          color: hsl(var(--primary-foreground));
          font-family: 'JetBrains Mono', monospace;
        }

        /* ===== Keyboard Shortcuts Modal ===== */
        .shortcuts-modal {
          display: none;
          position: fixed;
          inset: 0;
          background: hsl(var(--background) / 0.8);
          backdrop-filter: blur(4px);
          z-index: 100;
          align-items: center;
          justify-content: center;
        }

        .shortcuts-modal.open {
          display: flex;
        }

        .shortcuts-content {
          background: hsl(var(--card));
          border: 1px solid hsl(var(--border));
          border-radius: 0.5rem;
          padding: var(--space-6);
          max-width: 400px;
          width: 100%;
          box-shadow: var(--shadow-lg);
        }

        .shortcuts-title {
          font-size: 1rem;
          font-weight: 600;
          margin-bottom: var(--space-4);
        }

        .shortcut-group {
          margin-bottom: var(--space-4);
        }

        .shortcut-group-title {
          font-size: 0.75rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: hsl(var(--muted-foreground));
          margin-bottom: var(--space-2);
        }

        .shortcut-item {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: var(--space-2) 0;
        }

        .shortcut-key {
          display: flex;
          gap: var(--space-1);
        }

        .shortcut-key kbd {
          padding: var(--space-1) var(--space-2);
          background: hsl(var(--muted));
          border: 1px solid hsl(var(--border));
          border-radius: 0.25rem;
          font-family: 'JetBrains Mono', monospace;
          font-size: 0.75rem;
        }

        .shortcut-label {
          font-size: 0.875rem;
          color: hsl(var(--muted-foreground));
        }

        /* ===== Animations ===== */
        @keyframes fadeIn {
          from { opacity: 0; }
          to { opacity: 1; }
        }

        @keyframes slideIn {
          from { transform: translateY(-10px); opacity: 0; }
          to { transform: translateY(0); opacity: 1; }
        }

        @keyframes valueChange {
          0% { background: hsl(var(--crystal) / 0.3); }
          100% { background: transparent; }
        }

        .animate-fade-in {
          animation: fadeIn var(--transition-normal);
        }

        .animate-slide-in {
          animation: slideIn var(--transition-normal);
        }

        .value-changed {
          animation: valueChange 1s ease-out;
        }

        /* ===== Tooltip ===== */
        .tooltip {
          position: relative;
        }

        .tooltip-content {
          display: none;
          position: absolute;
          bottom: 100%;
          left: 50%;
          transform: translateX(-50%);
          padding: var(--space-2) var(--space-3);
          background: hsl(var(--popover));
          border: 1px solid hsl(var(--border));
          border-radius: 0.375rem;
          font-size: 0.75rem;
          white-space: nowrap;
          z-index: 50;
          box-shadow: var(--shadow-card);
        }

        .tooltip:hover .tooltip-content {
          display: block;
        }

        /* ===== Last Updated Indicator ===== */
        .last-updated {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          font-size: 0.75rem;
          color: hsl(var(--muted-foreground));
        }

        /* ===== Tab Pane (for backwards compat) ===== */
        .tab-pane {
          display: none;
        }

        .tab-pane.active {
          display: block;
        }

        /* ===== Header Text ===== */
        .header-text {
          color: hsl(var(--muted-foreground));
        }

        /* ===== Legacy Support ===== */
        .text-crystal { color: hsl(var(--crystal)); }
        .text-performance { color: hsl(var(--performance)); }

        /* ===== Golden Metrics Panel (Four Golden Signals) ===== */
        .golden-metrics {
          display: grid;
          grid-template-columns: repeat(4, 1fr);
          gap: var(--space-4);
          padding: var(--space-5);
          background: linear-gradient(135deg, hsl(var(--card)), hsl(var(--background)));
          border: 1px solid hsl(var(--border));
          border-radius: 0.75rem;
          margin-bottom: var(--space-6);
        }

        @media (max-width: 1200px) {
          .golden-metrics {
            grid-template-columns: repeat(2, 1fr);
          }
        }

        @media (max-width: 600px) {
          .golden-metrics {
            grid-template-columns: 1fr;
          }
        }

        .golden-metrics-header {
          grid-column: 1 / -1;
          display: flex;
          align-items: center;
          justify-content: space-between;
          margin-bottom: var(--space-2);
        }

        .golden-metrics-title {
          font-size: 0.875rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.1em;
          color: hsl(var(--muted-foreground));
        }

        .golden-signal {
          display: flex;
          flex-direction: column;
          padding: var(--space-4);
          background: hsl(var(--card));
          border-radius: 0.5rem;
          border: 1px solid hsl(var(--border) / 0.5);
          transition: all var(--transition-fast);
        }

        .golden-signal:hover {
          border-color: hsl(var(--border));
          box-shadow: var(--shadow-card);
        }

        .golden-signal-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          margin-bottom: var(--space-2);
        }

        .golden-signal-title {
          font-size: 0.7rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: hsl(var(--muted-foreground));
        }

        .golden-signal-icon {
          color: hsl(var(--muted-foreground));
          opacity: 0.7;
        }

        .golden-signal-value {
          font-size: 1.75rem;
          font-weight: 700;
          font-family: 'JetBrains Mono', monospace;
          line-height: 1.2;
          margin-bottom: var(--space-2);
        }

        .golden-signal-value.text-healthy {
          color: hsl(var(--status-healthy));
        }

        .golden-signal-value.text-warning {
          color: hsl(var(--status-warning));
        }

        .golden-signal-value.text-critical {
          color: hsl(var(--status-critical));
        }

        .golden-signal-sparkline {
          height: 32px;
          margin: var(--space-2) 0;
        }

        .golden-signal-details {
          display: flex;
          flex-direction: column;
          gap: 2px;
          font-size: 0.7rem;
          color: hsl(var(--muted-foreground));
          font-family: 'JetBrains Mono', monospace;
        }

        .golden-signal-status {
          display: flex;
          align-items: center;
          gap: var(--space-2);
          margin-top: var(--space-3);
          padding-top: var(--space-3);
          border-top: 1px solid hsl(var(--border) / 0.5);
          font-size: 0.75rem;
          font-weight: 500;
        }

        .golden-signal-status.healthy {
          color: hsl(var(--status-healthy));
        }

        .golden-signal-status.warning {
          color: hsl(var(--status-warning));
        }

        .golden-signal-status.critical {
          color: hsl(var(--status-critical));
        }

        .status-dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
        }

        .status-dot.healthy {
          background: hsl(var(--status-healthy));
        }

        .status-dot.warning {
          background: hsl(var(--status-warning));
        }

        .status-dot.critical {
          background: hsl(var(--status-critical));
        }

        .golden-progress {
          width: 100%;
          height: 8px;
          background: hsl(var(--muted));
          border-radius: 4px;
          overflow: hidden;
          margin: var(--space-2) 0;
        }

        .golden-progress-bar {
          height: 100%;
          border-radius: 4px;
          transition: width var(--transition-normal);
        }

        .golden-progress-bar.healthy {
          background: hsl(var(--status-healthy));
        }

        .golden-progress-bar.warning {
          background: hsl(var(--status-warning));
        }

        .golden-progress-bar.critical {
          background: hsl(var(--status-critical));
        }
        CSS
      end

      private def dashboard_scripts
        <<-JS
        // ===== Theme Management =====
        (function() {
            // Apply theme immediately to prevent flash
            const stored = localStorage.getItem('azu-dashboard-theme') || 'system';
            applyTheme(stored);
        })();

        function applyTheme(theme) {
            const root = document.documentElement;

            if (theme === 'system') {
                const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
                root.setAttribute('data-theme', prefersDark ? 'dark' : 'light');
            } else {
                root.setAttribute('data-theme', theme);
            }

            // Update active button state
            document.querySelectorAll('.theme-btn').forEach(btn => {
                btn.classList.toggle('active', btn.dataset.theme === theme);
            });
        }

        function setTheme(theme) {
            localStorage.setItem('azu-dashboard-theme', theme);
            applyTheme(theme);

            // Reinitialize icons after theme change
            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
        }

        // Listen for system theme changes
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
            const stored = localStorage.getItem('azu-dashboard-theme') || 'system';
            if (stored === 'system') {
                applyTheme('system');
            }
        });

        // ===== Initialize =====
        document.addEventListener('DOMContentLoaded', function() {
            // Initialize theme buttons
            const stored = localStorage.getItem('azu-dashboard-theme') || 'system';
            applyTheme(stored);

            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
            initKeyboardShortcuts();
            updateLastUpdated();
        });

        // ===== Section Navigation =====
        function showSection(sectionName) {
            // Hide all sections
            document.querySelectorAll('.section').forEach(section => {
                section.classList.remove('active');
            });

            // Remove active class from all nav items
            document.querySelectorAll('.nav-item').forEach(item => {
                item.classList.remove('active');
            });

            // Show selected section
            const targetSection = document.getElementById(sectionName);
            if (targetSection) {
                targetSection.classList.add('active');
            }

            // Add active class to clicked nav item
            const navItem = document.querySelector(`.nav-item[data-section="${sectionName}"]`);
            if (navItem) {
                navItem.classList.add('active');
            }
        }

        // Legacy tab support
        function showTab(tabName) {
            showSection(tabName === 'dashboard' ? 'overview' : tabName);
        }

        // ===== Auto Refresh =====
        let autoRefreshEnabled = true;
        let autoRefreshInterval;
        let lastRefreshTime = Date.now();

        function toggleAutoRefresh() {
            autoRefreshEnabled = !autoRefreshEnabled;
            const icon = document.getElementById('auto-refresh-icon');

            if (autoRefreshEnabled) {
                startAutoRefresh();
                if (icon) icon.setAttribute('data-lucide', 'timer');
            } else {
                stopAutoRefresh();
                if (icon) icon.setAttribute('data-lucide', 'timer-off');
            }

            // Reinitialize icons
            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
        }

        function startAutoRefresh() {
            if (autoRefreshInterval) clearInterval(autoRefreshInterval);
            autoRefreshInterval = setInterval(() => {
                if (autoRefreshEnabled) {
                    window.location.reload();
                }
            }, 30000);
        }

        function stopAutoRefresh() {
            if (autoRefreshInterval) {
                clearInterval(autoRefreshInterval);
                autoRefreshInterval = null;
            }
        }

        function updateLastUpdated() {
            setInterval(() => {
                const elapsed = Math.floor((Date.now() - lastRefreshTime) / 1000);
                const element = document.getElementById('last-updated');
                if (element) {
                    if (elapsed < 5) {
                        element.textContent = 'Updated now';
                    } else if (elapsed < 60) {
                        element.textContent = `Updated ${elapsed}s ago`;
                    } else {
                        element.textContent = `Updated ${Math.floor(elapsed / 60)}m ago`;
                    }
                }
            }, 1000);
        }

        // Start auto-refresh on page load
        startAutoRefresh();

        // ===== Actions =====
        function clearMetrics() {
            if (confirm('Are you sure you want to clear all performance metrics?')) {
                fetch(window.location.pathname + '?clear=true', { method: 'GET' })
                    .then(() => window.location.reload());
            }
        }

        function exportMetrics() {
            const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
            const filename = `azu-metrics-${timestamp}.json`;

            const metricsData = {
                timestamp: new Date().toISOString(),
                dashboard_url: window.location.href,
                export_info: "Azu Development Dashboard Metrics Export"
            };

            const blob = new Blob([JSON.stringify(metricsData, null, 2)], { type: 'application/json' });
            const url = URL.createObjectURL(blob);

            const a = document.createElement('a');
            a.href = url;
            a.download = filename;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        }

        function dismissInsights() {
            const panel = document.querySelector('.insights-panel');
            if (panel) {
                panel.style.display = 'none';
            }
        }

        // ===== Keyboard Shortcuts =====
        function initKeyboardShortcuts() {
            let gPressed = false;
            let gTimeout;

            document.addEventListener('keydown', function(e) {
                // Ignore if typing in input
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') {
                    return;
                }

                // Handle 'g' prefix for navigation
                if (e.key === 'g' && !gPressed) {
                    gPressed = true;
                    gTimeout = setTimeout(() => { gPressed = false; }, 1000);
                    return;
                }

                if (gPressed) {
                    clearTimeout(gTimeout);
                    gPressed = false;

                    switch (e.key) {
                        case 'o': showSection('overview'); break;
                        case 'e': showSection('errors'); break;
                        case 'q': showSection('requests'); break;
                        case 'd': showSection('database'); break;
                        case 'c': showSection('cache'); break;
                        case 'r': showSection('routes'); break;
                        case 'p': showSection('components'); break;
                    }
                    return;
                }

                // Single key shortcuts
                switch (e.key) {
                    case 'r':
                        e.preventDefault();
                        window.location.reload();
                        break;
                    case '/':
                        e.preventDefault();
                        const searchInput = document.querySelector('.table-search input');
                        if (searchInput) searchInput.focus();
                        break;
                    case 'e':
                        e.preventDefault();
                        exportMetrics();
                        break;
                    case '?':
                        e.preventDefault();
                        showShortcuts();
                        break;
                    case 'Escape':
                        hideShortcuts();
                        break;
                }
            });
        }

        function showShortcuts() {
            const modal = document.getElementById('shortcuts-modal');
            if (modal) {
                modal.classList.add('open');
            }
        }

        function hideShortcuts() {
            const modal = document.getElementById('shortcuts-modal');
            if (modal) {
                modal.classList.remove('open');
            }
        }

        // Close modal on click outside
        document.addEventListener('click', function(e) {
            const modal = document.getElementById('shortcuts-modal');
            if (modal && e.target === modal) {
                hideShortcuts();
            }
        });

        // ===== Table Interactivity =====
        function filterTable(tableId, query) {
            const table = document.getElementById(tableId);
            if (!table) return;

            const rows = table.querySelectorAll('tbody tr');
            const lowerQuery = query.toLowerCase();

            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                row.style.display = text.includes(lowerQuery) ? '' : 'none';
            });
        }

        function sortTable(tableId, columnIndex) {
            const table = document.getElementById(tableId);
            if (!table) return;

            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));

            const isAsc = table.dataset.sortDir !== 'asc';
            table.dataset.sortDir = isAsc ? 'asc' : 'desc';

            rows.sort((a, b) => {
                const aVal = a.cells[columnIndex].textContent.trim();
                const bVal = b.cells[columnIndex].textContent.trim();

                // Try numeric comparison first
                const aNum = parseFloat(aVal);
                const bNum = parseFloat(bVal);

                if (!isNaN(aNum) && !isNaN(bNum)) {
                    return isAsc ? aNum - bNum : bNum - aNum;
                }

                return isAsc ? aVal.localeCompare(bVal) : bVal.localeCompare(aVal);
            });

            rows.forEach(row => tbody.appendChild(row));
        }

        // ===== Initialization Complete =====
        if (typeof lucide !== 'undefined') {
            lucide.createIcons();
        }

        console.log('Azu Development Dashboard loaded');
        console.log('Press ? for keyboard shortcuts');
        JS
      end
    end
  end
end

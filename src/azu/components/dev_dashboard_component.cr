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
          metrics = monitor.metrics
          query_metrics = metrics.query_metrics
          n_plus_one_metrics = metrics.n_plus_one_metrics
          health_metrics = metrics.health_metrics

          {
            "total_queries"         => query_metrics.total_queries,
            "slow_queries"          => query_metrics.slow_queries,
            "very_slow_queries"     => query_metrics.very_slow_queries,
            "error_queries"         => query_metrics.error_queries,
            "avg_query_time"        => query_metrics.avg_execution_time.total_milliseconds,
            "min_query_time"        => query_metrics.min_execution_time.total_milliseconds,
            "max_query_time"        => query_metrics.max_execution_time.total_milliseconds,
            "error_rate"            => query_metrics.error_rate,
            "queries_per_second"    => query_metrics.queries_per_second,
            "slow_query_rate"       => query_metrics.slow_query_rate,
            "n_plus_one_patterns"   => n_plus_one_metrics.total_patterns,
            "critical_n_plus_one"   => n_plus_one_metrics.critical_patterns,
            "high_n_plus_one"       => n_plus_one_metrics.high_patterns,
            "database_health_score" => health_metrics.query_health_score,
            "monitoring_enabled"    => monitor.enabled?,
            "uptime"                => Time.utc - @start_time,
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
          metrics = monitor.metrics
          query_metrics = metrics.query_metrics
          n_plus_one_metrics = metrics.n_plus_one_metrics

          query_metrics.total_queries.to_i +
            query_metrics.slow_queries.to_i +
            query_metrics.very_slow_queries.to_i +
            n_plus_one_metrics.total_patterns
        {% else %}
          0 # CQL not available
        {% end %}
      rescue ex : Exception
        0
      end

      def collect_query_profiler_data
        {% if @top_level.has_constant?("CQL") %}
          monitor = CQL::Performance.monitor
          metrics = monitor.metrics
          query_metrics = metrics.query_metrics
          top_queries = metrics.top_queries

          {
            "unique_patterns"       => top_queries.most_frequent_queries.size,
            "total_executions"      => query_metrics.total_queries,
            "avg_performance_score" => calculate_performance_score(query_metrics),
            "slowest_pattern_time"  => query_metrics.max_execution_time.total_milliseconds,
            "most_frequent_count"   => top_queries.most_frequent_queries.first?.try(&.[:count]) || 0_i64,
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
          metrics = monitor.metrics
          n_plus_one_metrics = metrics.n_plus_one_metrics
          patterns = metrics.n_plus_one_patterns_by_severity(:all)

          {
            "issues"         => patterns.map(&.to_h.to_json),
            "total_issues"   => n_plus_one_metrics.total_patterns,
            "critical_count" => n_plus_one_metrics.critical_patterns,
            "high_count"     => n_plus_one_metrics.high_patterns,
            "medium_count"   => n_plus_one_metrics.medium_patterns,
            "low_count"      => n_plus_one_metrics.low_patterns,
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
          metrics = CQL::Performance.monitor.metrics
          slow_queries = metrics.top_queries.slowest_queries[0..20]

          slow_queries.map do |query|
            {
              "sql"            => query.sql,
              "normalized_sql" => query.normalized_sql,
              # "context"           => query.context || "N/A",
              "timestamp"         => query.timestamp.to_rfc3339,
              "rows_affected"     => query.rows_affected || 0_i64,
              "error"             => query.error || "None",
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
          metrics = CQL::Performance.monitor.metrics
          patterns = metrics.top_queries.most_frequent_queries[0..15]

          patterns.map do |pattern|
            {
              "normalized_sql"    => pattern[:sql],
              "execution_count"   => pattern[:count],
              "avg_time_ms"       => pattern[:avg_time].total_milliseconds,
              "performance_score" => calculate_query_performance_score(pattern),
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
            render_navigation
            render_header
            render_main_content
            render_scripts
          end
        end
      end

      private def render_navigation
        nav class: "nav" do
          div class: "nav-container" do
            div class: "nav-content" do
              div class: "nav-brand" do
                span { i "data-lucide": "gem" }
                span "Azu Development Dashboard"
              end
              div class: "nav-actions" do
                button class: "btn btn-outline", onclick: "window.location.reload()" do
                  i "data-lucide": "refresh-cw"
                  text "Refresh"
                end
                button class: "btn btn-default", onclick: "clearMetrics()" do
                  i "data-lucide": "trash-2"
                  text "Clear"
                end
                button class: "btn btn-outline", onclick: "exportMetrics()" do
                  i "data-lucide": "download"
                  text "Export"
                end
                button class: "btn btn-outline", onclick: "toggleAutoRefresh()" do
                  i "data-lucide": "refresh-cw"
                  text "Auto Refresh"
                  span id: "auto-refresh-status", class: "badge badge-default" do
                    text "ON"
                  end
                end
              end
            end
          end
        end
      end

      private def render_header
        div class: "header" do
          div class: "header-container" do
            para class: "header-text" do
              text "Live runtime insights and performance metrics for your Azu application"
            end
          end
        end
      end

      private def render_main_content
        div class: "main" do
          div class: "card" do
            div class: "tabs" do
              div class: "tabs-header" do
                div class: "tabs-list" do
                  button class: "tab-trigger active", onclick: "showTab('dashboard')" do
                    i "data-lucide": "gauge"
                    text "Dashboard"
                  end
                  button class: "tab-trigger", onclick: "showTab('errors')" do
                    i "data-lucide": "x-circle"
                    text "Error Logs"
                    span class: "badge badge-destructive" do
                      text @data_provider.collect_error_logs.size.to_s
                    end
                  end
                  button class: "tab-trigger", onclick: "showTab('routes')" do
                    i "data-lucide": "route"
                    text "Routes"
                    span class: "badge badge-default" do
                      text @data_provider.collect_routes_data.size.to_s
                    end
                  end
                  button class: "tab-trigger", onclick: "showTab('database')" do
                    i "data-lucide": "database"
                    text "DB"
                    span class: "badge badge-default" do
                      text @data_provider.collect_database_summary_count.to_s
                    end
                  end
                  button class: "tab-trigger", onclick: "showTab('cache')" do
                    i "data-lucide": "hard-drive"
                    text "DB Cache"
                    span class: "badge badge-default" do
                      text @data_provider.collect_cache_breakdown_count.to_s
                    end
                  end
                  button class: "tab-trigger", onclick: "showTab('components')" do
                    i "data-lucide": "layers"
                    text "Components"
                    span class: "badge badge-default" do
                      text @data_provider.collect_component_count.to_s
                    end
                  end
                end
              end

              div class: "tab-content" do
                render_dashboard_tab
                render_errors_tab
                render_routes_tab
                render_database_tab
                render_cache_tab
                render_components_tab
              end
            end
          end
        end
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
        :root {
              --background: 222.2 84% 4.9%;
              --foreground: 210 40% 98%;
              --card: 222.2 84% 4.9%;
              --card-foreground: 210 40% 98%;
              --popover: 222.2 84% 4.9%;
              --popover-foreground: 210 40% 98%;
              --primary: 210 40% 98%;
              --primary-foreground: 222.2 84% 4.9%;
              --secondary: 217.2 32.6% 17.5%;
              --secondary-foreground: 210 40% 98%;
              --muted: 217.2 32.6% 17.5%;
              --muted-foreground: 215 20.2% 65.1%;
              --accent: 217.2 32.6% 17.5%;
              --accent-foreground: 210 40% 98%;
              --destructive: 0 62.8% 30.6%;
              --destructive-foreground: 210 40% 98%;
              --border: 217.2 32.6% 17.5%;
              --input: 217.2 32.6% 17.5%;
              --ring: 212.7 26.8% 83.9%;
              --chart-1: 220 70% 50%;
              --chart-2: 160 60% 45%;
              --chart-3: 30 80% 55%;
              --chart-4: 280 65% 60%;
              --chart-5: 340 75% 55%;

              /* Azu Theme Colors */
              --crystal: 188 100% 44%;
              --performance: 160 84% 39%;
              --accent-azu: 45 93% 47%;
              --gradient-primary: linear-gradient(135deg, hsl(var(--performance)), hsl(var(--crystal)));
              --gradient-card: linear-gradient(145deg, hsl(var(--card)) / 0.5, hsl(var(--card)) / 0.8);
              --shadow-glow: 0 0 40px hsl(var(--performance)) / 0.3;
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

          /* Navigation */
          .nav {
              border-bottom: 1px solid hsl(var(--border));
              background: hsl(var(--card));
          }

          .nav-container {
              max-width: 1200px;
              margin: 0 auto;
              padding: 0 1rem;
          }

          .nav-content {
              display: flex;
              align-items: center;
              justify-content: space-between;
              height: 4rem;
          }

          .nav-brand {
              display: flex;
              align-items: center;
              gap: 0.5rem;
              font-size: 1.25rem;
              font-weight: 700;
              color: hsl(var(--foreground));
          }

          .nav-actions {
              display: flex;
              gap: 0.5rem;
          }

          .btn {
              display: inline-flex;
              align-items: center;
              gap: 0.5rem;
              padding: 0.5rem 1rem;
              border: none;
              border-radius: 0.375rem;
              font-weight: 600;
              text-decoration: none;
              transition: all 0.2s ease;
              cursor: pointer;
              font-size: 0.875rem;
          }

          .btn-outline {
              background: transparent;
              color: hsl(var(--foreground));
              border: 1px solid hsl(var(--border));
          }

          .btn-outline:hover {
              background: hsl(var(--accent));
          }

          .btn-default {
              background: hsl(var(--primary));
              color: hsl(var(--primary-foreground));
          }

          .btn-default:hover {
              background: hsl(var(--primary) / 0.9);
          }

          /* Header */
          .header {
              border-bottom: 1px solid hsl(var(--border));
              background: hsl(var(--card) / 0.5);
          }

          .header-container {
              max-width: 1200px;
              margin: 0 auto;
              padding: 1rem;
          }

          .header-text {
              color: hsl(var(--muted-foreground));
          }

          /* Main Content */
          .main {
              max-width: 1200px;
              margin: 0 auto;
              padding: 1.5rem 1rem;
          }

          .card {
              background: hsl(var(--card));
              border: 1px solid hsl(var(--border));
              border-radius: 0.5rem;
              box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
          }

          .card-large {
              box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
          }

          /* Tabs */
          .tabs {
              width: 100%;
          }

          .tabs-header {
              padding: 1.5rem 1.5rem 0;
          }

          .tabs-list {
              display: grid;
              grid-template-columns: repeat(6, 1fr);
              width: 100%;
              background: hsl(var(--muted));
              border-radius: 0.375rem;
              padding: 0.25rem;
          }

          @media (max-width: 1024px) {
              .tabs-list {
                  grid-template-columns: repeat(3, 1fr);
              }
          }

          @media (max-width: 768px) {
              .tabs-list {
                  grid-template-columns: repeat(2, 1fr);
              }
          }

          .tab-trigger {
              display: flex;
              align-items: center;
              justify-content: center;
              gap: 0.5rem;
              white-space: nowrap;
              border-radius: 0.25rem;
              padding: 0.375rem 0.75rem;
              font-size: 0.875rem;
              font-weight: 500;
              border: none;
              background: transparent;
              color: hsl(var(--muted-foreground));
              cursor: pointer;
              transition: all 0.2s ease;
          }

          .tab-trigger.active {
              background: hsl(var(--background));
              color: hsl(var(--foreground));
              box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
          }

          .badge {
              display: inline-flex;
              align-items: center;
              border-radius: 9999px;
              padding: 0.125rem 0.5rem;
              font-size: 0.75rem;
              font-weight: 600;
              line-height: 1;
              margin-left: 0.5rem;
          }

          .badge-destructive {
              background: hsl(var(--destructive));
              color: hsl(var(--destructive-foreground));
          }

          .badge-default {
              background: hsl(var(--primary));
              color: hsl(var(--primary-foreground));
          }

          .badge-outline {
              color: hsl(var(--foreground));
              border: 1px solid hsl(var(--border));
          }

          .badge-default {
              background: hsl(var(--primary));
              color: hsl(var(--primary-foreground));
          }

          /* Tab Content */
          .tab-content {
              padding: 1.5rem;
          }

          .tab-pane {
              display: none;
          }

          .tab-pane.active {
              display: block;
          }

          /* Grid Layout */
          .grid {
              display: grid;
              gap: 1.5rem;
          }

          .grid-cols-3 {
              grid-template-columns: repeat(3, 1fr);
          }

          @media (max-width: 1024px) {
              .grid-cols-3 {
                  grid-template-columns: repeat(2, 1fr);
              }
          }

          @media (max-width: 768px) {
              .grid-cols-3 {
                  grid-template-columns: 1fr;
              }
          }

          .mb-6 {
              margin-bottom: 1.5rem;
          }

          /* Metric Cards */
          .metric-card {
              background: var(--gradient-card);
              border: 1px solid hsl(var(--border) / 0.5);
          }

          .card-header {
              padding: 0.75rem 1.5rem;
              border-bottom: 1px solid hsl(var(--border));
          }

          .card-title {
              display: flex;
              align-items: center;
              gap: 0.5rem;
              font-size: 1.125rem;
              font-weight: 600;
              margin: 0;
          }

          .card-content {
              padding: 1.5rem;
          }

          .metric-list {
              display: flex;
              flex-direction: column;
              gap: 0.75rem;
          }

          .metric-item {
              display: flex;
              justify-content: space-between;
              align-items: center;
          }

          .metric-label {
              font-weight: 500;
          }

          .metric-value {
              font-size: 0.875rem;
              padding: 0.125rem 0.5rem;
              border-radius: 0.25rem;
              border: 1px solid hsl(var(--border));
          }

          .text-crystal {
              color: hsl(var(--crystal));
          }

          .text-performance {
              color: hsl(var(--performance));
          }

          .text-primary {
              color: hsl(var(--primary));
          }

          .text-accent {
              color: hsl(var(--accent-azu));
          }

          .text-muted-foreground {
              color: hsl(var(--muted-foreground));
          }

          /* Test Results */
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
              gap: 1rem;
          }

          @media (max-width: 768px) {
              .test-metrics {
                  grid-template-columns: repeat(2, 1fr);
              }
          }

          .test-metric {
              display: flex;
              flex-direction: column;
              gap: 0.25rem;
          }

          .test-metric-label {
              font-size: 0.875rem;
              color: hsl(var(--primary-foreground) / 0.8);
          }

          .test-metric-value {
              font-size: 0.875rem;
              font-weight: 500;
              color: hsl(var(--primary-foreground));
          }

          .progress {
              width: 100%;
              height: 0.5rem;
              background: hsl(var(--background) / 0.2);
              border-radius: 9999px;
              overflow: hidden;
          }

          .progress-bar {
              height: 100%;
              background: hsl(var(--performance));
              border-radius: 9999px;
              transition: width 0.3s ease;
          }

          /* Empty State */
          .empty-state {
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              padding: 3rem;
              text-align: center;
          }

          .empty-state svg {
              width: 4rem;
              height: 4rem;
              color: hsl(var(--performance));
              margin-bottom: 1rem;
          }

          .empty-state h4 {
              font-size: 1.25rem;
              font-weight: 600;
              margin-bottom: 0.5rem;
          }

          /* Routes Table */
          .table-container {
              overflow-x: auto;
          }

          .table {
              width: 100%;
              border-collapse: collapse;
          }

          .table th,
          .table td {
              text-align: left;
              padding: 0.75rem;
              border-bottom: 1px solid hsl(var(--border) / 0.5);
          }

          .table th {
              font-weight: 500;
          }

          .table tr:hover {
              background: hsl(var(--muted) / 0.5);
          }

          .table code {
              font-size: 0.75rem;
              background: hsl(var(--muted));
              padding: 0.25rem 0.5rem;
              border-radius: 0.25rem;
          }

          .sql-query {
              font-family: 'JetBrains Mono', 'Fira Code', 'Monaco', 'Consolas', monospace;
              font-size: 0.75rem;
              background: hsl(var(--muted));
              padding: 0.5rem;
              border-radius: 0.25rem;
              white-space: pre-wrap;
              word-wrap: break-word;
              max-width: 400px;
              max-height: 200px;
              overflow-y: auto;
              border: 1px solid hsl(var(--border) / 0.3);
              margin: 0;
              line-height: 1.4;
          }

          /* Icons */
          .icon {
              width: 1.25rem;
              height: 1.25rem;
              stroke: currentColor;
              fill: none;
              stroke-width: 2;
          }

          .icon-sm {
              width: 1rem;
              height: 1rem;
          }

          /* Tooltip */
          .tooltip {
              display: none;
              position: absolute;
              background: hsl(var(--popover));
              border: 1px solid hsl(var(--border));
              padding: 0.5rem;
              border-radius: 0.375rem;
              font-size: 0.75rem;
              max-width: 300px;
              word-wrap: break-word;
              z-index: 1000;
              box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
          }

          .badge:hover .tooltip {
              display: block;
          }

          /* SQL Query */
          .sql-query {
              font-family: 'JetBrains Mono', monospace;
              font-size: 0.75rem;
              background: hsl(var(--muted));
              padding: 0.5rem;
              border-radius: 0.375rem;
              white-space: pre-wrap;
              word-wrap: break-word;
              max-width: 400px;
              max-height: 200px;
              overflow-y: auto;
              border: 1px solid hsl(var(--border) / 0.3);
              margin: 0;
              line-height: 1.4;
          }

          /* Table Enhancements */
          .table td {
              vertical-align: top;
              padding: 0.75rem;
          }

          .table pre {
              margin: 0;
          }

          .badge {
              position: relative;
          }

          /* Status Colors */
          .text-performance {
              color: hsl(var(--performance));
          }

          .text-crystal {
              color: hsl(var(--crystal));
          }

          .text-accent {
              color: hsl(var(--accent-azu));
          }

          .text-destructive {
              color: hsl(var(--destructive));
          }

          /* Metric Value Enhancements */
          .metric-value {
              font-family: 'JetBrains Mono', monospace;
              font-size: 0.875rem;
              padding: 0.25rem 0.5rem;
              border-radius: 0.25rem;
              background: hsl(var(--muted) / 0.2);
          }

          .metric-value.text-performance {
              background: hsl(var(--performance) / 0.1);
          }

          .metric-value.text-crystal {
              background: hsl(var(--crystal) / 0.1);
          }

          .metric-value.text-accent {
              background: hsl(var(--accent-azu) / 0.1);
          }

          .metric-value.text-destructive {
              background: hsl(var(--destructive) / 0.1);
          }
        CSS
      end

      private def dashboard_scripts
        <<-JS
        // Initialize Lucide icons
        document.addEventListener('DOMContentLoaded', function() {
            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
        });

        function showTab(tabName) {
            // Hide all tab panes
            const panes = document.querySelectorAll('.tab-pane');
            panes.forEach(pane => pane.classList.remove('active'));

            // Remove active class from all triggers
            const triggers = document.querySelectorAll('.tab-trigger');
            triggers.forEach(trigger => trigger.classList.remove('active'));

            // Show selected tab pane
            document.getElementById(tabName).classList.add('active');

            // Add active class to clicked trigger
            event.currentTarget.classList.add('active');
        }

        let autoRefreshEnabled = true;
        let autoRefreshInterval;

        function clearMetrics() {
            if (confirm('Are you sure you want to clear all performance metrics?')) {
                fetch(window.location.pathname + '?clear=true', { method: 'GET' })
                    .then(() => window.location.reload());
            }
        }

        function exportMetrics() {
            const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
            const filename = `azu-metrics-${timestamp}.json`;

            // Collect current metrics data
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

        function toggleAutoRefresh() {
            autoRefreshEnabled = !autoRefreshEnabled;
            const statusElement = document.getElementById('auto-refresh-status');

            if (autoRefreshEnabled) {
                statusElement.textContent = 'ON';
                statusElement.className = 'badge badge-default';
                startAutoRefresh();
            } else {
                statusElement.textContent = 'OFF';
                statusElement.className = 'badge badge-outline';
                stopAutoRefresh();
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

        // Start auto-refresh on page load
        startAutoRefresh();

        // Re-initialize icons after page refresh
        if (typeof lucide !== 'undefined') {
            lucide.createIcons();
        }

        console.log('🚀 Azu Development Dashboard loaded');
        console.log('📊 Auto-refresh enabled (every 30 seconds)');
        JS
      end
    end
  end
end

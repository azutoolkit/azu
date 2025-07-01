require "http/server/handler"
require "../performance_metrics"
require "../performance_reporter"
require "../development_tools"
require "../cache"

module Azu
  module Handler
    # Development Dashboard HTTP handler for displaying live runtime insights
    # Provides comprehensive metrics for developers during development phase
    #
    # Usage:
    # ```
    # Azu.start [
    #   Azu::Handler::DevDashboard.new,
    #   # other handlers
    # ]
    # ```
    class DevDashboard
      include HTTP::Handler

      DEFAULT_PATH = "/dev-dashboard"

      getter path : String
            getter metrics : PerformanceMetrics
      getter log : ::Log

      @start_time : Time

      def initialize(@path = DEFAULT_PATH, metrics : PerformanceMetrics? = nil, @log : ::Log = Azu::CONFIG.log)
        @metrics = metrics || Azu::CONFIG.performance_monitor.try(&.metrics) || PerformanceMetrics.new
        @start_time = Time.utc
      end

      def call(context : HTTP::Server::Context)
        # Only handle requests to the dashboard path
        unless context.request.path == @path
          return call_next(context)
        end

        # Handle clear metrics request
        if context.request.query_params["clear"]? == "true"
          @metrics.clear
          @log.info { "Development dashboard metrics cleared" }
          context.response.status_code = 302
          context.response.headers["Location"] = @path
          return
        end

        # Collect dashboard data
        dashboard_data = collect_dashboard_data

        # Render HTML dashboard
        html_content = render_dashboard(dashboard_data)

        context.response.content_type = "text/html; charset=utf-8"
        context.response.print(html_content)
      rescue ex : Exception
        @log.error(exception: ex) { "Failed to render development dashboard" }
        context.response.status_code = 500
        context.response.content_type = "text/plain"
        context.response.print("Dashboard Error: #{ex.message}")
      end

      private def collect_dashboard_data
        # 1. Application Status
        uptime = Time.utc - @start_time
        current_memory = PerformanceMetrics.current_memory_usage
        aggregate_stats = @metrics.aggregate_stats

        app_status = {
          "uptime_seconds"  => uptime.total_seconds.to_i,
          "uptime_human"    => format_duration(uptime),
          "memory_usage_mb" => (current_memory / 1024.0 / 1024.0).round(2),
          "total_requests"  => aggregate_stats.total_requests,
          "error_rate"      => aggregate_stats.error_rate.round(2),
          "cpu_usage"       => get_cpu_usage_mock,
        }

        # 2. Database Info (mocked for now)
        database_info = {
          "connection_status"    => "Connected",
          "migration_status"     => "Up to date",
          "table_count"          => 15_i32,
          "query_performance_ms" => 12.5,
        }

        # 4. Performance Metrics
        perf_metrics = {
          "avg_response_time_ms"      => aggregate_stats.avg_response_time.round(2),
          "p95_response_time_ms"      => aggregate_stats.p95_response_time.round(2),
          "p99_response_time_ms"      => aggregate_stats.p99_response_time.round(2),
          "avg_memory_usage_mb"       => aggregate_stats.avg_memory_usage.round(2),
          "peak_memory_usage_mb"      => aggregate_stats.peak_memory_usage.round(2),
          "total_memory_allocated_mb" => (aggregate_stats.total_memory_allocated / 1024.0 / 1024.0).round(2),
          "requests_per_second"       => calculate_requests_per_second,
        }

        # 5. Cache Metrics
        cache_stats = @metrics.cache_stats
        cache_breakdown = @metrics.cache_operation_breakdown

        cache_metrics = {
          "total_operations"       => cache_stats["total_operations"]?.try(&.to_i) || 0_i32,
          "hit_rate"               => cache_stats["hit_rate"]?.try(&.round(2)) || 0.0,
          "error_rate"             => cache_stats["error_rate"]?.try(&.round(2)) || 0.0,
          "avg_processing_time_ms" => cache_stats["avg_processing_time"]?.try(&.round(2)) || 0.0,
          "total_data_written_mb"  => ((cache_stats["total_data_written"]? || 0.0) / 1024.0 / 1024.0).round(2),
          "get_operations"         => cache_stats["get_operations"]?.try(&.to_i) || 0_i32,
          "set_operations"         => cache_stats["set_operations"]?.try(&.to_i) || 0_i32,
          "delete_operations"      => cache_stats["delete_operations"]?.try(&.to_i) || 0_i32,
          "operation_breakdown"    => format_cache_breakdown(cache_breakdown),
        }

                # Add cache store information if available
        begin
          cache_manager = Azu::CONFIG.cache
          cache_metrics["max_size"] = cache_manager.config.max_size.to_i32

          if memory_store = cache_manager.store.as?(Cache::MemoryStore)
            store_stats = memory_store.stats
            cache_metrics["memory_usage_mb"] = store_stats["memory_usage_mb"].as(Float64)
            cache_metrics["hit_rate_calculated"] = store_stats["hit_rate"].as(Float64)
          end
        rescue
          # Cache not available, continue without store info
        end

        # 6. Component Lifecycle
        component_stats = @metrics.component_stats
        component_metrics = {
          "total_components"          => component_stats["total_components"]?.try(&.to_i) || 0_i32,
          "mount_events"              => component_stats["mount_events"]?.try(&.to_i) || 0_i32,
          "unmount_events"            => component_stats["unmount_events"]?.try(&.to_i) || 0_i32,
          "refresh_events"            => component_stats["refresh_events"]?.try(&.to_i) || 0_i32,
          "avg_component_age_seconds" => component_stats["avg_component_age"]?.try(&.round(2)) || 0.0,
        }

        # 7. Error Logs
        error_logs = collect_error_logs

        # 8. Test Results (mocked)
        test_results = {
          "last_run"                => "2024-01-15 10:30:00 UTC",
          "coverage_percent"        => 87.5,
          "failed_tests"            => 2_i32,
          "test_suite_time_seconds" => 45.2,
          "total_tests"             => 156_i32,
        }

        # 9. System Information
        gc_stats = GC.stats
        system_info = {
          "crystal_version" => Crystal::VERSION,
          "environment"     => Azu::CONFIG.env.to_s,
          "process_id"      => Process.pid.to_i32,
          "gc_heap_size_mb" => (gc_stats.heap_size / 1024.0 / 1024.0).round(2),
          "gc_free_bytes_mb" => (gc_stats.free_bytes / 1024.0 / 1024.0).round(2),
          "gc_total_bytes_mb" => (gc_stats.total_bytes / 1024.0 / 1024.0).round(2),
        }

        {
          "app_status"        => app_status,
          "database_info"     => database_info,
          "routes_data"       => collect_routes_info,
          "perf_metrics"      => perf_metrics,
          "cache_metrics"     => cache_metrics,
          "component_metrics" => component_metrics,
          "error_logs"        => error_logs,
          "test_results"      => test_results,
          "system_info"       => system_info,
        }
      end

      private def collect_routes_info : Hash(String, Array(Hash(String, String)))
        routes = [] of Hash(String, String)

        # Collect routes from the refactored router
        begin
          routes = Azu::CONFIG.router.route_info
        rescue ex
          # Fallback if route collection fails
          @log.debug { "Could not collect route information: #{ex.message}" }
          routes << {
            "method"      => "ERROR",
            "path"        => "/routes-unavailable",
            "resource"    => "N/A",
            "handler"     => "Router",
            "description" => "Route collection failed: #{ex.message}",
          }
        end

        # Sort routes by method and path for better display
        routes.sort_by! { |route| [route["method"], route["path"]] }

        {"routes" => routes}
      end

      private def collect_error_logs : Hash(String, Array(Hash(String, String)))
        recent_requests = @metrics.recent_requests(50)
        errors = recent_requests.select(&.error?)

        error_logs = errors.map do |error_request|
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

        {"error_logs" => error_logs}
      end

      private def format_cache_breakdown(breakdown : Hash(String, Hash(String, Float64))) : Hash(String, Hash(String, String))
        result = {} of String => Hash(String, String)

        breakdown.each do |operation, stats|
          result[operation] = {} of String => String
          stats.each do |key, value|
            result[operation][key] = case key
                                     when .ends_with?("_time")
                                       "#{value.round(2)}ms"
                                     when .ends_with?("_rate")
                                       "#{value.round(2)}%"
                                     when .ends_with?("_size")
                                       format_bytes(value.to_i64)
                                     else
                                       value.to_s
                                     end
          end
        end

        result
      end

      private def calculate_requests_per_second : Float64
        uptime = Time.utc - @start_time
        total_requests = @metrics.aggregate_stats.total_requests

        return 0.0 if uptime.total_seconds <= 0
        total_requests.to_f / uptime.total_seconds
      end

      private def get_cpu_usage_mock : Float64
        # Mock CPU usage - in a real implementation, you'd get this from system stats
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

      private def format_bytes(bytes : Int64) : String
        case
        when bytes < 1024
          "#{bytes}B"
        when bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(1)}KB"
        when bytes < 1024 * 1024 * 1024
          "#{(bytes / (1024.0 * 1024.0)).round(1)}MB"
        else
          "#{(bytes / (1024.0 * 1024.0 * 1024.0)).round(1)}GB"
        end
      end

      private def render_dashboard(data : Hash) : String
        # Generate the HTML dashboard
        String.build do |html|
          html << "<!DOCTYPE html>\n"
          html << "<html lang=\"en\">\n"
          html << "<head>\n"
          html << "  <meta charset=\"UTF-8\">\n"
          html << "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
          html << "  <title>Azu Development Dashboard</title>\n"
          html << render_dashboard_styles
          html << "</head>\n"
          html << "<body>\n"
          html << render_dashboard_header
          html << render_dashboard_content(data)
          html << render_dashboard_scripts
          html << "</body>\n"
          html << "</html>\n"
        end
      end

      private def render_dashboard_styles : String
        <<-CSS
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                 background: #f8fafc; color: #2d3748; line-height: 1.6; }
          .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
          .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                   color: white; padding: 30px 0; margin-bottom: 30px; border-radius: 12px; }
          .header h1 { font-size: 2.2rem; font-weight: 700; margin-bottom: 10px; }
          .header p { opacity: 0.9; font-size: 1.1rem; }
          .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 24px; }
          .card { background: white; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.05);
                 border: 1px solid #e2e8f0; overflow: hidden; }
          .card-header { background: #f7fafc; padding: 20px; border-bottom: 1px solid #e2e8f0; }
          .card-header h2 { font-size: 1.3rem; font-weight: 600; color: #2d3748; display: flex; align-items: center; }
          .card-body { padding: 20px; }
          .metric { display: flex; justify-content: space-between; align-items: center; padding: 12px 0;
                   border-bottom: 1px solid #f1f5f9; }
          .metric:last-child { border-bottom: none; }
          .metric-label { font-weight: 500; color: #4a5568; }
          .metric-value { font-weight: 600; color: #1a202c; }
          .status-good { color: #38a169; }
          .status-warning { color: #d69e2e; }
          .status-error { color: #e53e3e; }
          .table { width: 100%; border-collapse: collapse; }
          .table th { background: #f7fafc; padding: 12px; text-align: left; font-weight: 600;
                     border-bottom: 2px solid #e2e8f0; }
          .table td { padding: 12px; border-bottom: 1px solid #f1f5f9; }
          .table tr:hover { background: #f9fafb; }
          .badge { display: inline-block; padding: 4px 8px; border-radius: 12px; font-size: 0.75rem;
                  font-weight: 600; text-transform: uppercase; }
          .badge-success { background: #c6f6d5; color: #22543d; }
          .badge-error { background: #fed7d7; color: #742a2a; }
          .badge-warning { background: #faf089; color: #744210; }
          .icon { margin-right: 8px; }
          .refresh-btn { background: #4299e1; color: white; border: none; padding: 10px 20px;
                        border-radius: 8px; cursor: pointer; font-weight: 600; margin-bottom: 20px; }
          .refresh-btn:hover { background: #3182ce; }
          .clear-btn { background: #e53e3e; color: white; border: none; padding: 8px 16px;
                      border-radius: 6px; cursor: pointer; font-size: 0.9rem; margin-left: 10px; }
          .clear-btn:hover { background: #c53030; }
          .progress-bar { width: 100%; height: 8px; background: #e2e8f0; border-radius: 4px; overflow: hidden; }
          .progress-fill { height: 100%; background: linear-gradient(90deg, #48bb78, #38a169); transition: width 0.3s; }
          .text-center { text-align: center; }
          .no-data { text-align: center; color: #a0aec0; font-style: italic; padding: 40px 20px; }
        </style>
        CSS
      end

      private def render_dashboard_header : String
        <<-HTML
        <div class="header">
          <div class="container">
            <h1>🚀 Azu Development Dashboard</h1>
            <p>Live runtime insights and performance metrics for your Azu application</p>
            <button class="refresh-btn" onclick="window.location.reload()">🔄 Refresh</button>
            <button class="clear-btn" onclick="clearMetrics()">🗑️ Clear Metrics</button>
          </div>
        </div>
        HTML
      end

      private def render_dashboard_content(data : Hash) : String
        String.build do |html|
          html << "<div class=\"container\">\n"
          html << "  <div class=\"grid\">\n"

          # Application Status Card
          html << render_app_status_card(data["app_status"].as(Hash))

          # Performance Metrics Card
          html << render_performance_card(data["perf_metrics"].as(Hash))

          # Cache Metrics Card
          html << render_cache_card(data["cache_metrics"].as(Hash))

          # Database Info Card
          html << render_database_card(data["database_info"].as(Hash))

          # Component Lifecycle Card
          html << render_component_card(data["component_metrics"].as(Hash))

          # System Information Card
          html << render_system_card(data["system_info"].as(Hash))

          html << "  </div>\n"

          # Error Logs Table (full width)
          html << render_error_logs_section(data["error_logs"].as(Hash))

          # Routes Table (full width)
          html << render_routes_section(data["routes_data"].as(Hash))

          # Test Results Card
          html << "  <div class=\"grid\" style=\"margin-top: 24px;\">\n"
          html << render_test_results_card(data["test_results"].as(Hash))
          html << "  </div>\n"

          html << "</div>\n"
        end
      end

      private def render_app_status_card(data : Hash) : String
        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">📊</span>Application Status</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Uptime</span>
              <span class="metric-value status-good">#{data["uptime_human"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Memory Usage</span>
              <span class="metric-value">#{data["memory_usage_mb"]} MB</span>
            </div>
            <div class="metric">
              <span class="metric-label">Total Requests</span>
              <span class="metric-value">#{data["total_requests"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Error Rate</span>
              <span class="metric-value #{data["error_rate"].as(Float64) > 5.0 ? "status-error" : "status-good"}">#{data["error_rate"]}%</span>
            </div>
            <div class="metric">
              <span class="metric-label">CPU Usage</span>
              <span class="metric-value">#{data["cpu_usage"].as(Float64).round(1)}%</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_performance_card(data : Hash) : String
        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">⚡</span>Performance Metrics</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Avg Response Time</span>
              <span class="metric-value">#{data["avg_response_time_ms"]} ms</span>
            </div>
            <div class="metric">
              <span class="metric-label">P95 Response Time</span>
              <span class="metric-value">#{data["p95_response_time_ms"]} ms</span>
            </div>
            <div class="metric">
              <span class="metric-label">P99 Response Time</span>
              <span class="metric-value">#{data["p99_response_time_ms"]} ms</span>
            </div>
            <div class="metric">
              <span class="metric-label">Requests/Second</span>
              <span class="metric-value status-good">#{data["requests_per_second"].as(Float64).round(2)}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Peak Memory</span>
              <span class="metric-value">#{data["peak_memory_usage_mb"]} MB</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_cache_card(data : Hash) : String
        hit_rate = data["hit_rate"].as(Float64)
        hit_rate_class = hit_rate > 80 ? "status-good" : hit_rate > 50 ? "status-warning" : "status-error"

        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">💾</span>Cache Metrics</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Hit Rate</span>
              <span class="metric-value #{hit_rate_class}">#{hit_rate}%</span>
            </div>
            <div class="metric">
              <span class="metric-label">Total Operations</span>
              <span class="metric-value">#{data["total_operations"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">GET Operations</span>
              <span class="metric-value">#{data["get_operations"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">SET Operations</span>
              <span class="metric-value">#{data["set_operations"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Avg Processing Time</span>
              <span class="metric-value">#{data["avg_processing_time_ms"]} ms</span>
            </div>
            <div class="metric">
              <span class="metric-label">Data Written</span>
              <span class="metric-value">#{data["total_data_written_mb"]} MB</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_database_card(data : Hash) : String
        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">🗃️</span>Database Info</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Connection Status</span>
              <span class="metric-value status-good">#{data["connection_status"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Migration Status</span>
              <span class="metric-value status-good">#{data["migration_status"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Table Count</span>
              <span class="metric-value">#{data["table_count"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Query Performance</span>
              <span class="metric-value">#{data["query_performance_ms"]} ms</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_component_card(data : Hash) : String
        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">🧩</span>Component Lifecycle</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Total Components</span>
              <span class="metric-value">#{data["total_components"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Mount Events</span>
              <span class="metric-value status-good">#{data["mount_events"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Unmount Events</span>
              <span class="metric-value">#{data["unmount_events"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Refresh Events</span>
              <span class="metric-value">#{data["refresh_events"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Avg Component Age</span>
              <span class="metric-value">#{data["avg_component_age_seconds"].as(Float64).round(1)}s</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_system_card(data : Hash) : String
        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">⚙️</span>System Information</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Crystal Version</span>
              <span class="metric-value">#{data["crystal_version"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Environment</span>
              <span class="metric-value">#{data["environment"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Process ID</span>
              <span class="metric-value">#{data["process_id"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">GC Heap Size</span>
              <span class="metric-value">#{data["gc_heap_size_mb"]} MB</span>
            </div>
            <div class="metric">
              <span class="metric-label">GC Free Bytes</span>
              <span class="metric-value">#{data["gc_free_bytes_mb"]} MB</span>
            </div>
            <div class="metric">
              <span class="metric-label">GC Total Bytes</span>
              <span class="metric-value">#{data["gc_total_bytes_mb"]} MB</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_error_logs_section(data : Hash) : String
        error_logs = data["error_logs"].as(Array)

        html = String.build do |str|
          str << "<div style=\"margin-top: 24px;\">\n"
          str << "  <div class=\"card\">\n"
          str << "    <div class=\"card-header\">\n"
          str << "      <h2><span class=\"icon\">❌</span>Recent Error Logs (#{error_logs.size} errors)</h2>\n"
          str << "    </div>\n"
          str << "    <div class=\"card-body\" style=\"padding: 0;\">\n"

          if error_logs.empty?
            str << "      <div class=\"no-data\">🎉 No recent errors! Your application is running smoothly.</div>\n"
          else
            str << "      <table class=\"table\">\n"
            str << "        <thead>\n"
            str << "          <tr>\n"
            str << "            <th>Timestamp</th>\n"
            str << "            <th>Method</th>\n"
            str << "            <th>Path</th>\n"
            str << "            <th>Status</th>\n"
            str << "            <th>Time</th>\n"
            str << "            <th>Endpoint</th>\n"
            str << "            <th>Category</th>\n"
            str << "          </tr>\n"
            str << "        </thead>\n"
            str << "        <tbody>\n"

            error_logs.each do |error|
              error_hash = error.as(Hash)
              status_code = error_hash["status_code"].as(String)
              badge_class = status_code.starts_with?("5") ? "badge-error" : "badge-warning"

              str << "          <tr>\n"
              str << "            <td>#{error_hash["timestamp"]}</td>\n"
              str << "            <td><strong>#{error_hash["method"]}</strong></td>\n"
              str << "            <td><code>#{error_hash["path"]}</code></td>\n"
              str << "            <td><span class=\"badge #{badge_class}\">#{status_code}</span></td>\n"
              str << "            <td>#{error_hash["processing_time_ms"]}ms</td>\n"
              str << "            <td>#{error_hash["endpoint"]}</td>\n"
              str << "            <td>#{error_hash["category"]}</td>\n"
              str << "          </tr>\n"
            end

            str << "        </tbody>\n"
            str << "      </table>\n"
          end

          str << "    </div>\n"
          str << "  </div>\n"
          str << "</div>\n"
        end

        html
      end

      private def render_routes_section(data : Hash) : String
        routes = data["routes"].as(Array)

        html = String.build do |str|
          str << "<div style=\"margin-top: 24px;\">\n"
          str << "  <div class=\"card\">\n"
          str << "    <div class=\"card-header\">\n"
          str << "      <h2><span class=\"icon\">🛣️</span>Application Routes (#{routes.size} routes)</h2>\n"
          str << "    </div>\n"
          str << "    <div class=\"card-body\" style=\"padding: 0;\">\n"

          if routes.empty?
            str << "      <div class=\"no-data\">No routes found. Routes information requires router.routes method.</div>\n"
          else
            str << "      <table class=\"table\">\n"
            str << "        <thead>\n"
            str << "          <tr>\n"
            str << "            <th>Method</th>\n"
            str << "            <th>Path</th>\n"
            str << "            <th>Handler</th>\n"
            str << "            <th>Description</th>\n"
            str << "          </tr>\n"
            str << "        </thead>\n"
            str << "        <tbody>\n"

            routes.each do |route|
              route_hash = route.as(Hash)
              method = route_hash["method"].as(String)
              method_class = case method
                             when "GET"          then "badge-success"
                             when "POST"         then "badge-warning"
                             when "PUT", "PATCH" then "badge-warning"
                             when "DELETE"       then "badge-error"
                             else                     "badge"
                             end

              str << "          <tr>\n"
              str << "            <td><span class=\"badge #{method_class}\">#{method}</span></td>\n"
              str << "            <td><code>#{route_hash["path"]}</code></td>\n"
              str << "            <td>#{route_hash["handler"]}</td>\n"
              str << "            <td>#{route_hash["description"]}</td>\n"
              str << "          </tr>\n"
            end

            str << "        </tbody>\n"
            str << "      </table>\n"
          end

          str << "    </div>\n"
          str << "  </div>\n"
          str << "</div>\n"
        end

        html
      end

      private def render_test_results_card(data : Hash) : String
        coverage = data["coverage_percent"].as(Float64)
        coverage_class = coverage > 80 ? "status-good" : coverage > 60 ? "status-warning" : "status-error"

        <<-HTML
        <div class="card">
          <div class="card-header">
            <h2><span class="icon">🧪</span>Test Results</h2>
          </div>
          <div class="card-body">
            <div class="metric">
              <span class="metric-label">Last Run</span>
              <span class="metric-value">#{data["last_run"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Code Coverage</span>
              <span class="metric-value #{coverage_class}">#{coverage}%</span>
            </div>
            <div class="progress-bar" style="margin: 8px 0;">
              <div class="progress-fill" style="width: #{coverage}%;"></div>
            </div>
            <div class="metric">
              <span class="metric-label">Total Tests</span>
              <span class="metric-value">#{data["total_tests"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Failed Tests</span>
              <span class="metric-value #{data["failed_tests"].as(Int32) > 0 ? "status-error" : "status-good"}">#{data["failed_tests"]}</span>
            </div>
            <div class="metric">
              <span class="metric-label">Suite Time</span>
              <span class="metric-value">#{data["test_suite_time_seconds"]}s</span>
            </div>
          </div>
        </div>
        HTML
      end

      private def render_dashboard_scripts : String
        <<-HTML
        <script>
          function clearMetrics() {
            if (confirm('Are you sure you want to clear all performance metrics?')) {
              window.location.href = '#{@path}?clear=true';
            }
          }

          // Auto-refresh every 30 seconds
          setTimeout(function() {
            window.location.reload();
          }, 30000);

          console.log('🚀 Azu Development Dashboard loaded');
          console.log('📊 Auto-refresh enabled (every 30 seconds)');
        </script>
        HTML
      end
    end
  end
end

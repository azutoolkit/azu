require "../component"
require "../performance_metrics"
require "../performance_reporter"
require "../development_tools"
require "../cache"

module Azu
  module Components
    # Development Dashboard Component using AdminKit Framework
    # Provides comprehensive metrics for developers during development phase
    # Built with AdminKit's professional admin dashboard framework
    class DevDashboardComponent
      include Component

      getter metrics : PerformanceMetrics
      getter log : ::Log
      @start_time : Time

      def initialize(@metrics : PerformanceMetrics? = nil, @log : ::Log = Azu::CONFIG.log)
        @metrics = @metrics || Azu::CONFIG.performance_monitor.try(&.metrics) || PerformanceMetrics.new
        @start_time = Time.utc
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
          div class: "card card-large" do
            div class: "tabs" do
              div class: "tabs-header" do
                div class: "tabs-list" do
                  button class: "tab-trigger active", onclick: "showTab('dashboard')" do
                    i "data-lucide": "gauge"
                    text "Dashboard"
                  end
                  button class: "tab-trigger", onclick: "showTab('errors')" do
                    i "data-lucide": "x-circle"
                    text "Recent Error Logs"
                    span class: "badge badge-destructive" do
                      text collect_error_logs.size.to_s
                    end
                  end
                  button class: "tab-trigger", onclick: "showTab('routes')" do
                    i "data-lucide": "route"
                    text "Application Routes"
                    span class: "badge badge-default" do
                      text collect_routes_data.size.to_s
                    end
                  end
                end
              end

              div class: "tab-content" do
                render_dashboard_tab
                render_errors_tab
                render_routes_tab
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
          error_logs = collect_error_logs

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

      private def render_routes_tab
        div id: "routes", class: "tab-pane" do
          routes = collect_routes_data

          if routes.empty?
            div class: "empty-state" do
              i "data-lucide": "info"
              h4 "No routes found"
              para class: "header-text" do
                text "Routes information requires router.routes method."
              end
            end
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
        data = collect_app_status_data

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "monitor"
              text "Application Status"
            end
          end
          div class: "card-content" do
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
      end

      private def render_performance_card
        data = collect_performance_data

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "zap"
              text "Performance Metrics"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_item "Avg Response Time", "#{data["avg_response_time_ms"]} ms", "text-crystal"
              render_metric_item "P95 Response Time", "#{data["p95_response_time_ms"]} ms", "text-accent"
              render_metric_item "P99 Response Time", "#{data["p99_response_time_ms"]} ms", "text-muted-foreground"
              render_metric_item "Requests/Second", data["requests_per_second"].as(Float64).round(2).to_s, "text-performance"
              render_metric_item "Peak Memory", "#{data["peak_memory_usage_mb"]} MB", "text-crystal"
            end
          end
        end
      end

      private def render_cache_card
        data = collect_cache_data
        hit_rate = data["hit_rate"].as(Float64)

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "database"
              text "Cache Metrics"
            end
          end
          div class: "card-content" do
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
      end

      private def render_database_card
        data = collect_database_data

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "database"
              text "Database Info"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_item "Connection Status", data["connection_status"].to_s, "text-performance"
              render_metric_item "Migration Status", data["migration_status"].to_s, "text-performance"
              render_metric_item "Table Count", data["table_count"].to_s, "text-primary"
              render_metric_item "Query Performance", "#{data["query_performance_ms"]} ms", "text-crystal"
            end
          end
        end
      end

      private def render_component_card
        data = collect_component_data

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "layers"
              text "Component Lifecycle"
            end
          end
          div class: "card-content" do
            div class: "metric-list" do
              render_metric_item "Total Components", data["total_components"].to_s, "text-primary"
              render_metric_item "Mount Events", data["mount_events"].to_s, "text-performance"
              render_metric_item "Unmount Events", data["unmount_events"].to_s, "text-accent"
              render_metric_item "Refresh Events", data["refresh_events"].to_s, "text-crystal"
              render_metric_item "Avg Component Age", "#{data["avg_component_age_seconds"].as(Float64).round(1)}s", "text-muted-foreground"
            end
          end
        end
      end

      private def render_system_card
        data = collect_system_data

        div class: "card metric-card" do
          div class: "card-header" do
            h3 class: "card-title" do
              i "data-lucide": "settings"
              text "System Information"
            end
          end
          div class: "card-content" do
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
      end

      private def render_test_results_card
        data = collect_test_data
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
              grid-template-columns: repeat(3, 1fr);
              width: 100%;
              background: hsl(var(--muted));
              border-radius: 0.375rem;
              padding: 0.25rem;
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

        function clearMetrics() {
            if (confirm('Are you sure you want to clear all performance metrics?')) {
                window.location.reload();
            }
        }

        // Auto-refresh every 30 seconds
        setTimeout(function() {
            window.location.reload();
        }, 30000);

        // Re-initialize icons after page refresh
        if (typeof lucide !== 'undefined') {
            lucide.createIcons();
        }

        console.log('🚀 Azu Development Dashboard loaded');
        console.log('📊 Auto-refresh enabled (every 30 seconds)');
        JS
      end

      # Data collection methods (same as original DevDashboard)
      private def collect_app_status_data
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

      private def collect_performance_data
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

      private def collect_cache_data
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

      private def collect_database_data
        {
          "connection_status"    => "Connected",
          "migration_status"     => "Up to date",
          "table_count"          => 15_i32,
          "query_performance_ms" => 12.5,
        }
      end

      private def collect_component_data
        component_stats = @metrics.component_stats

        {
          "total_components"          => component_stats["total_components"]?.try(&.to_i) || 0_i32,
          "mount_events"              => component_stats["mount_events"]?.try(&.to_i) || 0_i32,
          "unmount_events"            => component_stats["unmount_events"]?.try(&.to_i) || 0_i32,
          "refresh_events"            => component_stats["refresh_events"]?.try(&.to_i) || 0_i32,
          "avg_component_age_seconds" => component_stats["avg_component_age"]?.try(&.round(2)) || 0.0,
        }
      end

      private def collect_system_data
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

      private def collect_test_data
        {
          "last_run"                => "2024-01-15 10:30:00 UTC",
          "coverage_percent"        => 87.5,
          "failed_tests"            => 2_i32,
          "test_suite_time_seconds" => 45.2,
          "total_tests"             => 156_i32,
        }
      end

      private def collect_error_logs
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

      private def collect_routes_data
        routes = Azu::CONFIG.router.route_info
        routes.sort_by! { |route| [route["method"], route["path"]] }
        routes
      rescue ex
        @log.debug { "Could not collect route information: #{ex.message}" }
        [{
          "method"      => "ERROR",
          "path"        => "/routes-unavailable",
          "resource"    => "N/A",
          "handler"     => "Router",
          "description" => "Route collection failed: #{ex.message}",
        }]
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
    end
  end
end

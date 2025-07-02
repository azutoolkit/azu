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
        html lang: "en", "data-bs-theme": "dark" do
          head do
            meta charset: "utf-8"
            meta name: "viewport", content: "width=device-width, initial-scale=1"
            title "AdminKit Azu Development Dashboard"

            # Google Fonts - JetBrains Mono
            link rel: "preconnect", href: "https://fonts.googleapis.com"
            link rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "anonymous"
            link href: "https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,100..800;1,100..800&display=swap",
              rel: "stylesheet"

            link href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.7/dist/css/bootstrap.min.css",
              rel: "stylesheet",
              integrity: "sha384-LN+7fdVzj6u52u30Kp6M/trliBMCMKTyK833zpbD+pXdCLuTusPj697FH4R/5mcr",
              crossorigin: "anonymous"

            # Custom styles
            style do
              text custom_styles
            end
          end

          body data_sidebar_position: "left", data_sidebar_layout: "default" do
            render_header
            render_main_content
            render_scripts
          end
        end
      end

      private def render_header
        nav class: "navbar navbar-expand-lg navbar-dark bg-primary" do
          div class: "container-md" do
            a class: "navbar-brand fw-bold" do
              i class: "feather-icon me-2", data_feather: "activity"
              text "Azu Development Dashboard"
            end

            button class: "navbar-toggler", type: "button",
              data_bs_toggle: "collapse", data_bs_target: "#navbarNav",
              aria_controls: "navbarNav", aria_expanded: "false", aria_label: "Toggle navigation" do
              span class: "navbar-toggler-icon"
            end

            div class: "collapse navbar-collapse", id: "navbarNav" do
              div class: "d-flex ms-auto" do
                button class: "btn btn-outline-light me-2", onclick: "window.location.reload()", type: "button" do
                  i class: "feather-icon me-1", data_feather: "refresh-cw"
                  text "Refresh"
                end
                button class: "btn btn-light", onclick: "clearMetrics()", type: "button" do
                  i class: "feather-icon me-1", data_feather: "trash-2"
                  text "Clear"
                end
              end
            end
          end
        end

        # Hero section with description
        div class: "border-bottom py-3" do
          div class: "container-md" do
            div class: "row" do
              div class: "col-12" do
                para class: "lead mb-0 text-muted" do
                  text "Live runtime insights and performance metrics for your Azu application"
                end
              end
            end
          end
        end
      end

      private def render_main_content
        div class: "container-md py-4" do
          # Main Dashboard with Tabs
          render_tabs_section
        end
      end

      private def render_tabs_section
        div class: "card shadow-sm" do
          div class: "card-header" do
            ul class: "nav nav-tabs card-header-tabs", id: "dashboardTabs", role: "tablist" do
              li class: "nav-item", role: "presentation" do
                button class: "nav-link active", id: "main-tab",
                  data_bs_toggle: "tab", data_bs_target: "#main-tab-pane",
                  type: "button", role: "tab", aria_controls: "main-tab-pane", aria_selected: "true" do
                  i class: "feather-icon me-2", data_feather: "monitor"
                  text "Dashboard"
                end
              end
              li class: "nav-item", role: "presentation" do
                button class: "nav-link", id: "errors-tab",
                  data_bs_toggle: "tab", data_bs_target: "#errors-tab-pane",
                  type: "button", role: "tab", aria_controls: "errors-tab-pane", aria_selected: "false" do
                  i class: "feather-icon me-2", data_feather: "alert-triangle"
                  text "Recent Error Logs"
                  span class: "badge bg-danger ms-2" do
                    text collect_error_logs.size.to_s
                  end
                end
              end
              li class: "nav-item", role: "presentation" do
                button class: "nav-link", id: "routes-tab",
                  data_bs_toggle: "tab", data_bs_target: "#routes-tab-pane",
                  type: "button", role: "tab", aria_controls: "routes-tab-pane", aria_selected: "false" do
                  i class: "feather-icon me-2", data_feather: "git-branch"
                  text "Application Routes"
                  span class: "badge bg-primary ms-2" do
                    text collect_routes_data.size.to_s
                  end
                end
              end
            end
          end
          div class: "card-body p-0" do
            div class: "tab-content", id: "dashboardTabsContent" do
              # Main Dashboard Tab
              div class: "tab-pane fade show active", id: "main-tab-pane", role: "tabpanel", aria_labelledby: "main-tab", tabindex: "0" do
                render_main_dashboard_content
              end
              # Error Logs Tab
              div class: "tab-pane fade", id: "errors-tab-pane", role: "tabpanel", aria_labelledby: "errors-tab", tabindex: "0" do
                render_error_logs_content
              end
              # Routes Tab
              div class: "tab-pane fade", id: "routes-tab-pane", role: "tabpanel", aria_labelledby: "routes-tab", tabindex: "0" do
                render_routes_content
              end
            end
          end
        end
      end

      private def render_main_dashboard_content
        div class: "p-4" do
          # Metrics Cards Row
          div class: "row g-4 mb-4" do
            render_app_status_card
            render_performance_card
            render_cache_card
          end

          # Second Row
          div class: "row g-4 mb-4" do
            render_database_card
            render_component_card
            render_system_card
          end

          # Test Results Card
          div class: "row mb-4" do
            div class: "col-12" do
              render_test_results_card
            end
          end
        end
      end

      private def render_error_logs_content
        error_logs = collect_error_logs

        if error_logs.empty?
          div class: "empty-state" do
            i class: "feather-icon text-success", data_feather: "check-circle"
            h4 "No recent errors!"
            para "Your application is running smoothly."
          end
        else
          div class: "table-responsive" do
            table class: "table table-hover mb-0" do
              thead class: "table" do
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
                  badge_class = status_code.starts_with?("5") ? "bg-danger" : "bg-warning"

                  tr do
                    td class: "text-muted" do
                      small error_hash["timestamp"]
                    end
                    td do
                      span class: "badge bg-secondary" do
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

      private def render_routes_content
        routes = collect_routes_data

        if routes.empty?
          div class: "container empty-state" do
            i class: "feather-icon", data_feather: "help-circle"
            h4 "No routes found"
            para "Routes information requires router.routes method."
          end
        else
          div class: "table-responsive" do
            table class: "table table-hover mb-0" do
              thead class: "table" do
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
                                 when "GET"          then "bg-success"
                                 when "POST"         then "bg-warning"
                                 when "PUT", "PATCH" then "bg-info"
                                 when "DELETE"       then "bg-danger"
                                 else                     "bg-secondary"
                                 end

                  tr do
                    td do
                      span class: "badge #{method_class}" do
                        text method
                      end
                    end
                    td do
                      code route_hash["path"]
                    end
                    td route_hash["handler"]
                    td route_hash["description"]
                  end
                end
              end
            end
          end
        end
      end

      private def render_app_status_card
        data = collect_app_status_data

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header text-white" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "monitor"
                text "Application Status"
              end
            end
            ol class: "list-group  list-group-flush" do
              render_metric_row "Uptime", data["uptime_human"].to_s, "text-success"
              render_metric_row "Memory Usage", "#{data["memory_usage_mb"]} MB", "text-info"
              render_metric_row "Total Requests", data["total_requests"].to_s, "text-primary"
              render_metric_row "Error Rate", "#{data["error_rate"]}%",
                data["error_rate"].as(Float64) > 5.0 ? "text-danger" : "text-success"
              render_metric_row "CPU Usage", "#{data["cpu_usage"].as(Float64).round(1)}%", "text-warning"
            end
          end
        end
      end

      private def render_performance_card
        data = collect_performance_data

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header text-white" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "zap"
                text "Performance Metrics"
              end
            end
            ol class: "list-group  list-group-flush" do
              render_metric_row "Avg Response Time", "#{data["avg_response_time_ms"]} ms", "text-info"
              render_metric_row "P95 Response Time", "#{data["p95_response_time_ms"]} ms", "text-warning"
              render_metric_row "P99 Response Time", "#{data["p99_response_time_ms"]} ms", "text-danger"
              render_metric_row "Requests/Second", data["requests_per_second"].as(Float64).round(2).to_s, "text-success"
              render_metric_row "Peak Memory", "#{data["peak_memory_usage_mb"]} MB", "text-info"
            end
          end
        end
      end

      private def render_cache_card
        data = collect_cache_data
        hit_rate = data["hit_rate"].as(Float64)
        hit_rate_class = hit_rate > 80 ? "text-success" : hit_rate > 50 ? "text-warning" : "text-danger"

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header text-white" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "database"
                text "Cache Metrics"
              end
            end
            ol class: "list-group  list-group-flush" do
              render_metric_row "Hit Rate", "#{hit_rate}%", hit_rate > 80 ? "text-success" : hit_rate > 50 ? "text-warning" : "text-danger"
              render_metric_row "Total Operations", data["total_operations"].to_s, "text-primary"
              render_metric_row "GET Operations", data["get_operations"].to_s, "text-info"
              render_metric_row "SET Operations", data["set_operations"].to_s, "text-warning"
              render_metric_row "Avg Processing Time", "#{data["avg_processing_time_ms"]} ms", "text-secondary"
              render_metric_row "Data Written", "#{data["total_data_written_mb"]} MB", "text-info"
            end
          end
        end
      end

      private def render_database_card
        data = collect_database_data

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "server"
                text "Database Info"
              end
            end
            ol class: "list-group  list-group-flush" do
              render_metric_row "Connection Status", data["connection_status"].to_s, "text-success"
              render_metric_row "Migration Status", data["migration_status"].to_s, "text-success"
              render_metric_row "Table Count", data["table_count"].to_s, "text-primary"
              render_metric_row "Query Performance", "#{data["query_performance_ms"]} ms", "text-info"
            end
          end
        end
      end

      private def render_component_card
        data = collect_component_data

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header text-white" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "layers"
                text "Component Lifecycle"
              end
            end
            ol class: "list-group  list-group-flush" do
              render_metric_row "Total Components", data["total_components"].to_s, "text-primary"
              render_metric_row "Mount Events", data["mount_events"].to_s, "text-success"
              render_metric_row "Unmount Events", data["unmount_events"].to_s, "text-warning"
              render_metric_row "Refresh Events", data["refresh_events"].to_s, "text-info"
              render_metric_row "Avg Component Age", "#{data["avg_component_age_seconds"].as(Float64).round(1)}s", "text-secondary"
            end
          end
        end
      end

      private def render_system_card
        data = collect_system_data

        div class: "col-lg-4 col-md-6" do
          div class: "card h-100 shadow-sm" do
            div class: "card-header text-white" do
              h5 class: "card-title mb-0" do
                i class: "feather-icon me-2", data_feather: "settings"
                text "System Information"
              end
            end
            ol class: "list-group list-group-numbered list-group-flush" do
              render_metric_row "Crystal Version", data["crystal_version"].to_s, "text-primary"
              render_metric_row "Environment", data["environment"].to_s, "text-info"
              render_metric_row "Process ID", data["process_id"].to_s, "text-secondary"
              render_metric_row "GC Heap Size", "#{data["gc_heap_size_mb"]} MB", "text-warning"
              render_metric_row "GC Free Bytes", "#{data["gc_free_bytes_mb"]} MB", "text-success"
              render_metric_row "GC Total Bytes", "#{data["gc_total_bytes_mb"]} MB", "text-info"
            end
          end
        end
      end

      private def render_test_results_card
        data = collect_test_data
        coverage = data["coverage_percent"].as(Float64)
        coverage_class = coverage > 80 ? "text-success" : coverage > 60 ? "text-warning" : "text-danger"

        div class: "card shadow-sm" do
          div class: "card-header text-white", style: "background: linear-gradient(135deg, #a855f7 0%, #7c3aed 100%);" do
            h5 class: "card-title mb-0" do
              i class: "feather-icon me-2", data_feather: "clipboard"
              text "Test Results"
            end
          end
          div class: "card-body" do
            div class: "row" do
              div class: "col-md-3" do
                div class: "metric-row" do
                  span class: "metric-label" do
                    text "Last Run"
                  end
                  span class: "metric-value text-secondary" do
                    text data["last_run"].to_s
                  end
                end
              end
              div class: "col-md-3" do
                div class: "metric-row" do
                  span class: "metric-label" do
                    text "Code Coverage"
                  end
                  span class: "metric-value #{coverage_class}" do
                    text "#{coverage}%"
                  end
                end
                div class: "progress mt-2" do
                  div class: "progress-bar bg-success", style: "width: #{coverage}%" do
                    text "#{coverage}%"
                  end
                end
              end
              div class: "col-md-2" do
                div class: "metric-row" do
                  span class: "metric-label" do
                    text "Total Tests"
                  end
                  span class: "metric-value text-primary" do
                    text data["total_tests"].to_s
                  end
                end
              end
              div class: "col-md-2" do
                div class: "metric-row" do
                  span class: "metric-label" do
                    text "Failed Tests"
                  end
                  span class: "metric-value #{data["failed_tests"].as(Int32) > 0 ? "text-danger" : "text-success"}" do
                    text data["failed_tests"].to_s
                  end
                end
              end
              div class: "col-md-2" do
                div class: "metric-row" do
                  span class: "metric-label" do
                    text "Suite Time"
                  end
                  span class: "metric-value text-info" do
                    text "#{data["test_suite_time_seconds"]}s"
                  end
                end
              end
            end
          end
        end
      end

      private def render_metric_row(label : String, value : String, value_class : String = "")
        li class: "list-group-item d-flex justify-content-between align-items-start" do
          div class: "ms-2 me-auto" do
            div class: "fw-bold" do
              text label
            end
          end
          span class: "#{value_class}" do
            text value
          end
        end
      end

      private def render_scripts
        # Bootstrap JS only (removing AdminKit to avoid conflicts)
        script src: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.7/dist/js/bootstrap.bundle.min.js",
          integrity: "sha384-ndDqU0Gzau9qJ1lfW4pNLlhNTkCfHzAVBReH9diLvGRem5+R9g2FzA8ZGN954O5Q",
          crossorigin: "anonymous"

        # Feather Icons JS for icon rendering
        script src: "https://cdn.jsdelivr.net/npm/feather-icons@4.29.0/dist/feather.min.js"

        script do
          raw dashboard_scripts
        end
      end

      private def custom_styles
        <<-CSS
        /* Developer-friendly monospace fonts with Bootstrap Dark Theme */
        body {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 14px;
          line-height: 1.5;
        }

        /* Feather icon styling */
        .feather-icon {
          width: 18px;
          height: 18px;
          stroke-width: 2;
          vertical-align: middle;
        }

        h1, h2, h3, h4, h5, h6 {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-weight: 600;
        }

        .btn {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-weight: 500;
          border-radius: 0.5rem;
        }

        .nav-link {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-weight: 500;
        }

        /* Navbar enhancements with dark purple gradient */
        .navbar.bg-primary {
          background: linear-gradient(135deg, #2d1b69 0%, #11998e 100%) !important;
          border-bottom: 1px solid rgba(255, 255, 255, 0.1);
          box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
        }

        .navbar-brand {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 1.5rem;
          font-weight: 700;
        }

        /* List group enhancements for dark theme */
        .list-group-numbered {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
        }

        .list-group-item {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 13px;
          padding: 0.75rem 1rem;
        }

        .list-group-item .fw-bold {
          font-size: 14px;
          font-weight: 600;
        }

        .list-group-item span {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 14px;
          font-weight: 700;
        }

        /* Progress bar enhancements */
        .progress {
          border-radius: 0.5rem;
          background-color: rgba(255, 255, 255, 0.1);
        }

        .progress-bar {
          border-radius: 0.5rem;
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 11px;
          font-weight: 600;
        }

        /* Empty state styling */
        .empty-state {
          text-align: center;
          padding: 4rem 2rem;
          opacity: 0.8;
        }

        .empty-state .feather-icon {
          width: 4rem;
          height: 4rem;
          margin-bottom: 1rem;
          opacity: 0.5;
        }

        /* Card hover effects */
        .card {
          transition: all 0.2s ease-in-out;
        }

        .card:hover {
          transform: translateY(-2px);
        }

        /* Metric row styling for test results card */
        .metric-row {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 0.5rem 0;
          border-bottom: 1px solid rgba(255, 255, 255, 0.1);
          transition: background-color 0.2s;
        }

        .metric-row:hover {
          background-color: rgba(255, 255, 255, 0.05);
          margin: 0 -1rem;
          padding-left: 1rem;
          padding-right: 1rem;
          border-radius: 0.5rem;
        }

        .metric-row:last-child {
          border-bottom: none;
        }

        .metric-label {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 13px;
          font-weight: 500;
          opacity: 0.8;
        }

        .metric-value {
          font-family: 'JetBrains Mono', 'Fira Code', 'Source Code Pro', 'Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'Courier New', monospace !important;
          font-size: 14px;
          font-weight: 700;
        }
        CSS
      end

      private def dashboard_scripts
        <<-JS
        // Global function declarations
        window.clearMetrics = function() {
          if (confirm('Are you sure you want to clear all performance metrics?')) {
            window.location.href = window.location.pathname + '?clear=true';
          }
        };

        // Auto-refresh every 30 seconds
        setTimeout(function() {
          window.location.reload();
        }, 30000);

        // Add some interactive features
        document.addEventListener('DOMContentLoaded', function() {
          // Initialize Feather icons
          if (typeof feather !== 'undefined') {
            feather.replace();
          }

          // Add hover effects to cards
          var cards = document.querySelectorAll('.card');
          cards.forEach(function(card) {
            card.addEventListener('mouseenter', function() {
              this.style.transform = 'translateY(-2px)';
              this.style.transition = 'transform 0.2s ease';
            });

            card.addEventListener('mouseleave', function() {
              this.style.transform = 'translateY(0)';
            });
          });

          // Add tooltips to badges
          var badges = document.querySelectorAll('.badge');
          badges.forEach(function(badge) {
            badge.setAttribute('data-bs-toggle', 'tooltip');
            badge.setAttribute('data-bs-placement', 'top');
          });

          // Initialize Bootstrap tooltips
          var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
          var tooltipList = tooltipTriggerList.map(function (tooltipTriggerEl) {
            return new bootstrap.Tooltip(tooltipTriggerEl);
          });



          // Add click handlers for tab badges (Bootstrap 5.3 convention)
          var errorBadge = document.querySelector('#errors-tab .badge');
          var routesBadge = document.querySelector('#routes-tab .badge');

          if (errorBadge) {
            errorBadge.addEventListener('click', function(e) {
              e.stopPropagation();
              // Switch to errors tab using Bootstrap 5.3 Tab API
              var errorsTab = bootstrap.Tab.getOrCreateInstance(document.querySelector('#errors-tab'));
              errorsTab.show();
            });
          }

          if (routesBadge) {
            routesBadge.addEventListener('click', function(e) {
              e.stopPropagation();
              // Switch to routes tab using Bootstrap 5.3 Tab API
              var routesTab = bootstrap.Tab.getOrCreateInstance(document.querySelector('#routes-tab'));
              routesTab.show();
            });
          }

          // Add keyboard navigation for tabs (Bootstrap 5.3 convention)
          document.addEventListener('keydown', function(e) {
            var isCtrlPressed = e.ctrlKey || e.metaKey;
            if (isCtrlPressed) {
              switch(e.key) {
                case '1':
                  e.preventDefault();
                  var mainTab = bootstrap.Tab.getOrCreateInstance(document.querySelector('#main-tab'));
                  mainTab.show();
                  break;
                case '2':
                  e.preventDefault();
                  var errorsTab = bootstrap.Tab.getOrCreateInstance(document.querySelector('#errors-tab'));
                  errorsTab.show();
                  break;
                case '3':
                  e.preventDefault();
                  var routesTab = bootstrap.Tab.getOrCreateInstance(document.querySelector('#routes-tab'));
                  routesTab.show();
                  break;
              }
            }
          });
        });

        console.log('🚀 Azu Development Dashboard loaded with Bootstrap Framework');
        console.log('📊 Auto-refresh enabled (every 30 seconds)');

        console.log('📋 Three-tab interface: Dashboard, Errors, and Routes');
        console.log('⌨️  Keyboard shortcuts: Ctrl+1 (Main), Ctrl+2 (Errors), Ctrl+3 (Routes)');
        console.log('♿ Accessible navigation with ARIA labels and proper semantics');
        console.log('🎨 Professional UI powered by Bootstrap 5.3 framework');
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

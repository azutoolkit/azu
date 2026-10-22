require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Overview" tab: health strip, the four headline KPIs and one summary card
      # per subsystem. Every figure comes from DashboardDataProvider; whatever
      # cannot be measured renders the explicit "n/a" state instead of a guess.
      module OverviewSection
        private abstract def provider : DashboardDataProvider

        private def render_overview : Nil
          render_attention
          div class: "azd-grid azd-kpis" do
            render_uptime_kpi
            render_memory_kpi
            render_latency_kpi
            render_routes_kpi
          end
          div class: "azd-grid azd-cards" do
            render_traffic_card
            render_errors_card
            render_cache_summary
            render_database_summary
            render_components_summary
            render_runtime_card
          end
        end

        private def render_attention : Nil
          score = provider.health_score
          insights = provider.insights
          section class: "azd-card azd-attention" do
            render_health_ring(score, Status.floor(score.to_f, 90.0, 70.0))
            div class: "azd-attention-body" do
              h3 insights.empty? ? "All systems nominal" : "#{insights.size} #{insights.size == 1 ? "item needs" : "items need"} attention"
              if insights.empty?
                paragraph "No errors, slow responses or query problems in the recorded traffic."
              else
                ul class: "azd-insights" do
                  insights.first(5).each { |insight| render_insight(insight) }
                end
              end
            end
          end
        end

        private def render_health_ring(score : Int32, status : Status) : Nil
          circumference = 2 * Math::PI * 26
          raw %(<svg class="azd-ring #{status.css}" viewBox="0 0 64 64" role="img" aria-label="Health score #{score} out of 100">) +
              %(<circle class="azd-ring-track" cx="32" cy="32" r="26"/>) +
              %(<circle class="azd-ring-value" cx="32" cy="32" r="26" stroke-dasharray="#{circumference.round(1)}" stroke-dashoffset="#{(circumference * (1 - score / 100.0)).round(1)}"/>) +
              %(<text x="32" y="37" text-anchor="middle">#{score}</text></svg>)
        end

        private def render_insight(insight : DashboardDataProvider::Insight) : Nil
          li class: "azd-insight" do
            badge insight.status, insight.status.severity
            div do
              strong insight.message
              span insight.detail, class: "azd-muted"
            end
            button "View", type: "button", class: "azd-link", data_action: "tab", data_tab: insight.tab, aria_label: "View #{insight.message}"
          end
        end

        private def render_uptime_kpi : Nil
          kpi "Uptime", "clock" do
            kpi_value Format.uptime(provider.uptime), caption: "Since #{provider.start_time.to_s("%b %-d, %H:%M:%S")} UTC"
          end
        end

        private def render_memory_kpi : Nil
          rss = provider.rss_bytes
          heap = Format.megabytes(provider.runtime.heap)
          leak = provider.memory_leak_suspected?
          kpi "Memory (RSS)", "memory", leak ? Status::Warn : nil, "Possible leak" do
            kpi_value rss.try { |bytes| (bytes / 1024.0 / 1024.0).round(1).to_s }, "MB",
              caption: rss ? "GC heap #{heap}" : "RSS unavailable on this OS - GC heap #{heap}"
            sparkline provider.memory_series, "GC heap samples"
          end
        end

        private def render_latency_kpi : Nil
          latency = provider.latency
          status = latency.try { |stats| Status.latency(stats.p99) }
          wording = status.try(&.pick("Fast", "Slow", "Spike")) || ""
          kpi("Latency", "tracing", status, wording) do
            if latency
              div class: "azd-kpi-pair" do
                kpi_value(*Format.ms_parts(latency.p50), caption: "p50")
                kpi_value(*Format.ms_parts(latency.p99), caption: "p99")
              end
              sparkline provider.latency_series, "Latency of the newest requests"
            else
              kpi_value nil, caption: "No requests recorded yet"
            end
          end
        end

        private def render_routes_kpi : Nil
          routes = provider.routes
          kpi "Active routes", "routes" do
            kpi_value routes.size.to_s, caption: routes.empty? ? "No routes registered" : routes.group_by { |route| route["method"] }.map { |verb, group| "#{group.size} #{verb}" }.join(" / ")
          end
        end

        private def render_traffic_card : Nil
          card "Traffic", "tracing" do
            facts do
              fact "Requests", Format.number(provider.stats.total_requests)
              fact "Throughput", "#{provider.requests_per_second.round(2)} req/s"
            end
            sparkline provider.traffic_series, "Requests over time"
          end
        end

        private def render_errors_card : Nil
          rate = provider.stats.error_rate
          errors = provider.recent_errors
          card "Errors", "alert" do
            facts do
              fact("Error rate") { badge Status.ceiling(rate, 1.0, 5.0), Format.percent(rate) }
              fact "Failed requests", Format.number(provider.stats.error_requests)
            end
            if errors.empty?
              empty_state "No recent errors", "The newest #{DashboardDataProvider::ERROR_WINDOW} requests all succeeded."
            else
              ul class: "azd-mini-list" do
                errors.first(4).each { |error| render_error_row(error) }
              end
              button "Open logs", type: "button", class: "azd-link", data_action: "tab", data_tab: "logs"
            end
          end
        end

        private def render_error_row(error : PerformanceMetrics::RequestMetric) : Nil
          li do
            badge Status.http(error.status_code), error.status_code.to_s
            verb_chip error.method
            span error.path, class: "azd-trunc"
          end
        end

        private def render_cache_summary : Nil
          cache = provider.cache_stats
          card "Cache", "cache" do
            if cache.gets.zero?
              empty_state "n/a", "No cache reads recorded yet.", "cache"
            else
              status = Status.floor(cache.hit_rate, 80.0, 50.0)
              meter cache.hit_rate, status, "Cache hit rate"
              facts do
                fact("Hit rate") { badge status, Format.percent(cache.hit_rate) }
                fact "Operations", Format.number(cache.total)
                fact "Average time", Format.ms(cache.avg_ms)
              end
            end
          end
        end

        private def render_database_summary : Nil
          db = provider.database_stats
          card "Database", "database" do
            if db.active
              facts do
                fact "Queries", Format.number(db.queries)
                fact("Slow queries") { badge zero_is_good(db.slow, Status::Warn), db.slow.to_s }
                fact("N+1 patterns") { badge zero_is_good(db.n_plus_one, Status::Bad), db.n_plus_one.to_s }
                fact "Average time", Format.ms(db.avg_ms)
              end
            else
              empty_state "n/a", "CQL performance monitoring is not active.", "database"
            end
          end
        end

        private def render_components_summary : Nil
          components = provider.component_stats
          card "Components", "components" do
            facts do
              fact "Active", components.active.to_s
              fact "Mounts / unmounts", "#{components.mounts} / #{components.unmounts}"
              fact "Refreshes", components.refreshes.to_s
              fact "Average age", "#{components.avg_age.round(1)}s"
            end
          end
        end

        private def render_runtime_card : Nil
          runtime = provider.runtime
          card "Runtime", "config" do
            facts do
              fact "Crystal", runtime.crystal
              fact "Environment", runtime.environment
              fact "Process ID", runtime.pid.to_s
              fact "GC heap", Format.megabytes(runtime.heap)
            end
          end
        end
      end
    end
  end
end

require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Cache" tab: hit rate, operation mix and the latest operations.
      module CacheSection
        private abstract def provider : DashboardDataProvider

        private def render_cache : Nil
          render_cache_kpis
          render_cache_breakdown
          render_recent_cache_operations
        end

        private def render_cache_kpis : Nil
          cache = provider.cache_stats
          div class: "azd-grid azd-kpis" do
            render_hit_rate_kpi(cache)
            kpi "Operations", "cache" do
              kpi_value Format.number(cache.total), caption: "#{cache.gets} get / #{cache.sets} set / #{cache.deletes} delete"
            end
            kpi "Error rate", "alert", Status.ceiling(cache.error_rate, 1.0, 5.0), "Errors" do
              kpi_value Format.percent(cache.error_rate)
            end
            kpi "Average time", "clock" do
              kpi_value(*Format.ms_parts(cache.avg_ms), caption: "#{Format.megabytes(cache.written_bytes.to_i64)} written")
            end
          end
        end

        private def render_hit_rate_kpi(cache : DashboardDataProvider::CacheStats) : Nil
          status = Status.floor(cache.hit_rate, 80.0, 50.0)
          wording = status.pick("Healthy", "Low", "Poor")
          kpi("Hit rate", "cache", (cache.gets.zero? ? nil : status), wording) do
            if cache.gets.zero?
              kpi_value nil, caption: "No cache reads recorded yet"
            else
              kpi_value Format.percent(cache.hit_rate), caption: "#{cache.gets} reads"
              meter cache.hit_rate, status, "Cache hit rate"
            end
          end
        end

        private def render_cache_breakdown : Nil
          breakdown = provider.cache_breakdown
          card "Operation breakdown", "logs" do
            if breakdown.empty?
              empty_state "No cache operations recorded", "Operations appear as the cache is used.", "cache"
            else
              data_table "Cache operation breakdown", ["Operation", "Count", "Average", "Errors", "Hit rate"] do
                breakdown.each do |operation, stats|
                  tr data_filter: nil do
                    td { verb_chip operation.upcase }
                    td Format.number(stats["count"].to_i)
                    td Format.ms(stats["avg_time"])
                    td { badge Status.ceiling(stats["error_rate"], 1.0, 5.0), Format.percent(stats["error_rate"]) }
                    td { present(stats["hit_rate"]?) { |rate| badge Status.floor(rate, 80.0, 50.0), Format.percent(rate) } }
                  end
                end
              end
            end
          end
        end

        private def render_recent_cache_operations : Nil
          operations = provider.recent_cache_operations
          card "Recent operations", "clock", meta: "newest first" do
            if operations.empty?
              empty_state "No recent cache operations", "The latest operations are listed here.", "cache"
            else
              data_table "Recent cache operations", ["Time", "Operation", "Key", "Store", "Result", "Duration", "Status"] do
                operations.each { |operation| render_cache_row(operation) }
              end
            end
          end
        end

        private def render_cache_row(operation : PerformanceMetrics::CacheMetric) : Nil
          tr data_filter: nil do
            td Format.clock(operation.timestamp), class: "azd-mono"
            td { verb_chip operation.operation.upcase }
            td class: "azd-mono azd-wrap" do
              text operation.key
            end
            td operation.store_type
            td do
              operation.hit? ? badge(Status::Good, "Hit") : (operation.miss? ? badge(Status::Warn, "Miss") : na)
            end
            td Format.ms(operation.processing_time)
            td { operation.successful? ? badge(Status::Good, "OK") : badge(Status::Bad, operation.error || "Error") }
          end
        end
      end
    end
  end
end

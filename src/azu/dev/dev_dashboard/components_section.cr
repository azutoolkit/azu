require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Components" tab: live component lifecycle counters and the latest events.
      module ComponentsSection
        private abstract def provider : DashboardDataProvider

        private def render_components : Nil
          stats = provider.component_stats
          div class: "azd-grid azd-kpis" do
            kpi("Active components", "components") { kpi_value stats.active.to_s, caption: "Average age #{stats.avg_age.round(1)}s" }
            kpi("Mounts", "components") { kpi_value Format.number(stats.mounts) }
            kpi("Unmounts", "components") { kpi_value Format.number(stats.unmounts) }
            kpi("Refreshes", "refresh") { kpi_value Format.number(stats.refreshes) }
          end
          render_component_events
        end

        private def render_component_events : Nil
          events = provider.recent_component_events
          card "Recent events", "clock", meta: "newest first" do
            if events.empty?
              empty_state "No component events recorded", "Mount, unmount and refresh events appear as live components run.", "components"
            else
              data_table "Recent component events", ["Time", "Component", "Event", "Duration", "Memory change"] do
                events.each { |event| render_component_row(event) }
              end
            end
          end
        end

        private def render_component_row(event : PerformanceMetrics::ComponentMetric) : Nil
          tr data_filter: nil do
            td Format.clock(event.timestamp), class: "azd-mono"
            td event.component_type, class: "azd-mono"
            td event.event
            td { present(event.processing_time) { |millis| text Format.ms(millis) } }
            td { present(event.memory_delta) { |bytes| text Format.megabytes(bytes) } }
          end
        end
      end
    end
  end
end

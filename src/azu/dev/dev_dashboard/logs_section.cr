require "./data_provider"

module Azu
  module Components
    module Dashboard
      # "Logs" tab: a compact newest-first stream of request, cache and component
      # events. Each entry is a native `<details>` drawer holding its request /
      # response inspector, so it is keyboard and screen-reader friendly with no
      # script. Verbosity is a row of level toggles (debug starts hidden through
      # the stream's `data-off` list, see dashboard.css) and the quick filter
      # searches the entry's plain-text rendering in `data-filter`.
      module LogsSection
        private abstract def provider : DashboardDataProvider

        private def render_logs : Nil
          entries = provider.log_entries
          card "Event stream", "logs", meta: "UTC" do
            render_level_toggles(entries)
            if entries.empty?
              empty_state "No events recorded yet", "Requests, cache operations and component events appear here once the PerformanceMonitor handler records them.", "logs"
            else
              ol class: "azd-stream", data_off: Level::Debug.css do
                entries.each { |entry| li { render_log_entry(entry) } }
              end
            end
          end
        end

        private def render_level_toggles(entries : Array(DashboardDataProvider::LogEntry)) : Nil
          counts = entries.tally_by(&.level)
          div class: "azd-seg", role: "group", aria_label: "Log verbosity" do
            Level.each do |level|
              button type: "button", class: "azd-seg-btn lvl-#{level.css}", data_action: "level", data_level: level.css,
                aria_pressed: level.debug? ? "false" : "true" do
                text level.to_s
                span counts.fetch(level, 0).to_s, class: "azd-count"
              end
            end
          end
        end

        private def render_log_entry(entry : DashboardDataProvider::LogEntry) : Nil
          details class: "azd-log lvl-#{entry.level.css}", data_level: entry.level.css, data_filter: entry.to_text, data_palette: "log" do
            summary do
              time Format.clock(entry.time), datetime: entry.time.to_rfc3339(fraction_digits: 3), class: "azd-log-time"
              span entry.level.to_s.upcase, class: "azd-level"
              verb_chip entry.tag
              span entry.message, class: "azd-log-msg"
              entry.status.try { |code| span code.to_s, class: "azd-http #{Status.http(code).css}" }
              entry.duration_ms.try { |millis| span Format.ms(millis), class: "azd-dur #{Status.latency(millis).css}" }
            end
            div class: "azd-log-body" do
              entry.panes.each { |pane| render_pane(pane) }
              entry.link.try { |url| a "Open the exception page", href: url, class: "azd-link azd-log-link" }
              copy_button "log entry"
            end
          end
        end

        private def render_pane(pane : DashboardDataProvider::Pane) : Nil
          div class: "azd-pane" do
            h4 pane.title
            facts do
              pane.rows.each { |key, value| fact key, value }
            end
          end
        end
      end
    end
  end
end

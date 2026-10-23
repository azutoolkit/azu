require "html"
require "../component"
require "./performance_metrics"
require "./performance_reporter"
require "./development_tools"
require "../cache"
require "./dev_dashboard/data_provider"
require "./dev_dashboard/widgets"
require "./dev_dashboard/overview_section"
require "./dev_dashboard/routes_section"
require "./dev_dashboard/logs_section"
require "./dev_dashboard/tracing_section"
require "./dev_dashboard/database_section"
require "./dev_dashboard/cache_section"
require "./dev_dashboard/components_section"
require "./dev_dashboard/config_section"

module Azu
  module Components
    # The development dashboard: one self-contained HTML document (inline CSS, JS
    # and SVG icons; no CDN, webfont or other external request) showing live
    # runtime diagnostics for the app it is mounted in.
    #
    # ## Component breakdown
    #
    # * Header and quick filter: `render_header` and `render_filter`; `.azd-top`, `applyFilters` in the script
    # * Sidebar and tabs: `render_nav` and `render_panels`; `.azd-nav`, ARIA tablist driven by `selectTab`
    # * Command palette: `render_palette`, a native modal `<dialog>`; `.azd-palette`, `openPalette`
    # * Theme and toast: the header theme button and the `#azd-toast` live region; `light-dark()` tokens, `setTheme`, `toast`
    # * KPI and metric cards: `Widgets#kpi` and `Widgets#card`; `.azd-kpi`, `.azd-card`, `.azd-spark`
    # * Log viewer and request inspector: `LogsSection`, one `<details>` drawer per entry; level toggles, `.azd-log`
    # * Route tree: `RoutesSection#render_route_tree`; `.azd-tree`, colour-coded `.azd-verb` chips
    # * Middleware graph: `RoutesSection#render_pipeline`; the numbered `.azd-pipeline` flow
    # * Tracing, Database, Cache, Components, Config: one `*Section` module each
    #
    # Files, all next to this one in `dev_dashboard/`:
    # * `data_provider.cr` (`DashboardDataProvider`): every number shown, memoized per render
    # * `*_section.cr`: one mixin per tab, rendering through the Markup DSL
    # * `widgets.cr`, `status.cr`, `format.cr`: shared building blocks and vocabulary
    # * `dashboard.css`, `dashboard.js`, `theme_boot.js`, `icons.svg`: static assets embedded at compile time
    #
    # ## State handling
    #
    # The server renders every tab up front, so the data needs no script (without it
    # a `<noscript>` rule simply stacks all panels). `dashboard.js` keeps one `state` object (active tab,
    # filter text, verb and level toggles, auto-refresh) and a soft refresh swaps
    # only the `[data-live]` regions, so a refresh never loses the open tab or filters.
    # Theme and sidebar choices persist in localStorage (guarded, so blocked storage
    # simply means defaults).
    #
    # ## Styling
    #
    # All CSS lives under the `.azd` body class using custom-property design tokens
    # (colours via `light-dark()`, so one declaration serves both themes), keeping it
    # from leaking into any host page.
    #
    # ## Security
    #
    # Request data is attacker-controlled. Every dynamic value goes through the
    # Markup DSL (`HTML.escape`d as text or attribute); `raw` only carries static
    # assets and numeric SVG data, and the script reads the DOM with `textContent`.
    class DevDashboardComponent
      include Component
      include Dashboard::Widgets
      include Dashboard::OverviewSection
      include Dashboard::RoutesSection
      include Dashboard::LogsSection
      include Dashboard::TracingSection
      include Dashboard::DatabaseSection
      include Dashboard::CacheSection
      include Dashboard::ComponentsSection
      include Dashboard::ConfigSection

      alias Status = Dashboard::Status

      # One navigation entry; `group` titles the sidebar section it appears under.
      record Tab, id : String, label : String, icon : String, group : String, summary : String

      TABS = [
        Tab.new("overview", "Overview", "overview", "Monitor", "Health, traffic and runtime at a glance"),
        Tab.new("logs", "Logs", "logs", "Monitor", "Requests, cache operations and component events as they happen"),
        Tab.new("routes", "Routes", "routes", "Application", "The middleware pipeline and every registered endpoint"),
        Tab.new("components", "Components", "components", "Application", "Live component lifecycle"),
        Tab.new("tracing", "Performance Tracing", "tracing", "Performance", "Where request time goes"),
        Tab.new("database", "Database", "database", "Performance", "Query statistics, slow statements and N+1 patterns"),
        Tab.new("cache", "Cache", "cache", "Performance", "Hit rate, operation mix and recent operations"),
        Tab.new("config", "Config", "config", "System", "Operational switches of the running app"),
      ]

      STYLES     = {{ read_file("#{__DIR__}/dev_dashboard/dashboard.css") }}
      SCRIPT     = {{ read_file("#{__DIR__}/dev_dashboard/dashboard.js") }}
      THEME_BOOT = {{ read_file("#{__DIR__}/dev_dashboard/theme_boot.js") }}
      ICONS      = {{ read_file("#{__DIR__}/dev_dashboard/icons.svg") }}

      getter metrics : PerformanceMetrics
      getter log : ::Log
      getter start_time : Time

      private getter provider : DashboardDataProvider

      # `start_time` should be when the app booted (the handler passes its own), so
      # uptime is meaningful even though a component is built per request.
      def initialize(metrics : PerformanceMetrics? = nil, @log : ::Log = Azu.current_config.log, @start_time : Time = Time.utc)
        @metrics = metrics || Azu.current_config.performance_monitor.try(&.metrics) || PerformanceMetrics.new
        @provider = DashboardDataProvider.new(@metrics, @start_time, @log)
      end

      # The dashboard is a whole document, so it skips Component#render's
      # `<div data-spark-view>` wrapper (which also pushed the doctype out of first
      # position and put the page in quirks mode).
      def render : String
        content
        to_s
      ensure
        @view = IO::Memory.new
      end

      def content : Nil
        raw "<!DOCTYPE html>"
        html lang: "en" do
          head do
            meta charset: "utf-8"
            meta name: "viewport", content: "width=device-width, initial-scale=1"
            meta name: "color-scheme", content: "dark light"
            title "Azu Development Dashboard"
            link rel: "icon", href: "data:,"
            style { raw STYLES }
            noscript { style { raw ".azd .azd-panel { display: block; }" } }
          end
          body class: "azd" do
            script { raw THEME_BOOT }
            raw ICONS
            a "Skip to content", href: "#azd-main", class: "azd-skip"
            render_header
            div class: "azd-shell" do
              render_nav
              render_main
            end
            render_palette
            div id: "azd-toast", class: "azd-toast", role: "status", aria_live: "polite"
            div id: "azd-announce", class: "azd-sr", role: "status", aria_live: "polite"
            script { raw SCRIPT }
          end
        end
      end

      private def render_header : Nil
        header class: "azd-top" do
          h1 "Azu Development Dashboard", class: "azd-sr"
          icon_button "Collapse sidebar", "sidebar", "sidebar", aria_pressed: "false", aria_controls: "azd-nav"
          a href: "#overview", class: "azd-brand", data_action: "tab", data_tab: "overview" do
            icon "gem"
            text "Azu"
            span "Dev", class: "azd-brand-tag"
          end
          span Azu.current_config.env.to_s.downcase, class: "azd-chip azd-env"
          render_filter
          render_actions
        end
      end

      private def render_filter : Nil
        div class: "azd-filter" do
          icon "search"
          label "Filter this view", for: "azd-filter", class: "azd-sr"
          input id: "azd-filter", type: "search", placeholder: "Filter routes, logs, tables", autocomplete: "off", spellcheck: "false"
          kbd "/"
        end
      end

      private def render_actions : Nil
        div class: "azd-actions" do
          button type: "button", class: "azd-btn", data_action: "palette", aria_haspopup: "dialog", aria_keyshortcuts: "Control+K Meta+K" do
            icon "search"
            span "Search", class: "azd-btn-label"
            kbd "Ctrl K", class: "azd-mod"
          end
          button type: "button", class: "azd-btn", data_action: "auto", aria_pressed: "true", title: "Toggle live auto-refresh" do
            span class: "azd-live-dot"
            span "Live", id: "azd-updated"
            span class: "azd-btn-label", id: "azd-age"
          end
          icon_button "Refresh now", "refresh", "refresh"
          icon_button "Clear recorded metrics", "trash", "clear"
          button type: "button", class: "azd-icon-btn", data_action: "theme", aria_label: "Switch theme" do
            icon "sun", "azd-sun"
            icon "moon", "azd-moon"
          end
        end
      end

      private def render_nav : Nil
        nav id: "azd-nav", class: "azd-nav", aria_label: "Dashboard sections" do
          div class: "azd-tablist", role: "tablist", aria_orientation: "vertical" do
            previous_group = nil
            TABS.each_with_index do |tab, index|
              span tab.group, class: "azd-nav-group", aria_hidden: "true" unless tab.group == previous_group
              previous_group = tab.group
              render_tab(tab, index.zero?)
            end
          end
        end
      end

      private def render_tab(tab : Tab, selected : Bool) : Nil
        button type: "button", role: "tab", id: "tab-#{tab.id}", class: "azd-tab", data_action: "tab", data_tab: tab.id,
          aria_controls: "panel-#{tab.id}", aria_selected: selected.to_s, tabindex: selected ? "0" : "-1", title: tab.label do
          icon tab.icon
          span tab.label, class: "azd-tab-label"
          render_tab_count(tab)
        end
      end

      # Small count next to a tab label; always rendered (hidden when empty) so a
      # live refresh can fill it in.
      private def render_tab_count(tab : Tab) : Nil
        count, status = case tab.id
                        when "routes"   then {provider.routes.size, Status::Idle}
                        when "logs"     then {provider.recent_errors.size, Status::Bad}
                        when "database" then {provider.database_stats.slow, Status::Warn}
                        else                 {0, Status::Idle}
                        end
        span count.zero? ? "" : count.to_s, id: "count-#{tab.id}", class: "azd-count #{status.css}", data_live: nil
      end

      private def render_main : Nil
        main id: "azd-main", class: "azd-main", tabindex: "-1" do
          render_exposure_banner
          div id: "azd-panels", data_live: nil do
            render_panels
          end
        end
      end

      # The handler is not gated by environment, so outside development say so loudly.
      private def render_exposure_banner : Nil
        env = Azu.current_config.env
        return unless env.production? || env.staging?

        div class: "azd-banner", role: "alert" do
          icon "alert"
          text "This dashboard is exposed in #{env.to_s.downcase}. It reveals process internals: remove Azu::Handler::DevDashboard from the handler list or restrict access to it."
        end
      end

      private def render_panels : Nil
        TABS.each_with_index do |tab, index|
          section id: "panel-#{tab.id}", class: "azd-panel#{" is-active" if index.zero?}", role: "tabpanel", aria_labelledby: "tab-#{tab.id}" do
            header class: "azd-panel-head" do
              h2 tab.label
              paragraph tab.summary
            end
            render_tab_content(tab.id)
          end
        end
      end

      private def render_tab_content(id : String) : Nil
        case id
        when "overview"   then render_overview
        when "logs"       then render_logs
        when "routes"     then render_routes
        when "components" then render_components
        when "tracing"    then render_tracing
        when "database"   then render_database
        when "cache"      then render_cache
        when "config"     then render_config
        end
      end

      # Ctrl/Cmd+K palette. A native modal <dialog> supplies the focus trap, Esc to
      # close and an inert page behind it; the combobox/listbox roles are wired up
      # by dashboard.js, which fills the list from the page's own routes, logs and tabs.
      private def render_palette : Nil
        dialog id: "azd-palette", class: "azd-palette", aria_label: "Command palette" do
          div class: "azd-palette-box" do
            div class: "azd-palette-input" do
              icon "search"
              input id: "azd-palette-input", type: "text", role: "combobox", aria_expanded: "true", aria_controls: "azd-palette-list",
                aria_autocomplete: "list", aria_label: "Search routes, logs and tabs", placeholder: "Search routes, logs and tabs",
                autocomplete: "off", spellcheck: "false"
              kbd "Esc"
            end
            ul id: "azd-palette-list", class: "azd-palette-list", role: "listbox", aria_label: "Results"
            paragraph "Up and Down to move, Enter to open, Esc to close", class: "azd-palette-hint"
          end
        end
      end
    end
  end
end

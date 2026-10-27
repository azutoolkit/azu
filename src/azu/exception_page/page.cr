require "../markup"
require "../ui/widgets"
require "../ui/format"
require "./registry"

module Azu
  # The development exception page: what failed, where in the app, the likely causes and the signals recorded
  # around it, in the dev dashboard's look (`ui/dashboard.css`, light and dark). One self-contained document with
  # no external request. It is only rendered in development; production answers with the `error.html` template.
  #
  # The page reads a `Report`, so the dev dashboard renders the same page later from a stored report
  # (`/dev-dashboard/errors/<id>`), with `occurrence` placing it among the reports of its fingerprint.
  #
  # Request data is attacker-controlled: every value goes through the Markup DSL, which escapes it.
  class ExceptionPage
    include Markup
    include Components::Dashboard::Widgets

    alias Status = Components::Dashboard::Status
    alias Format = Components::Dashboard::Format

    STYLES      = {{ read_file("#{__DIR__}/../ui/dashboard.css") }}
    PAGE_STYLES = {{ read_file("#{__DIR__}/page.css") }}
    SCRIPT      = {{ read_file("#{__DIR__}/page.js") }}
    THEME_BOOT  = {{ read_file("#{__DIR__}/../ui/theme_boot.js") }}
    ICONS       = {{ read_file("#{__DIR__}/../ui/icons.svg") }}

    MAX_HERO_HINTS = 3

    getter report : Report
    getter occurrence : Occurrence?

    def initialize(@report : Report, @occurrence : Occurrence? = nil)
    end

    # The page for `exception` while serving `context`. Query parameters, headers and cookies are redacted with
    # `Azu::Env.redact`, so a credential in them does not reach the browser.
    def self.redacted(context : HTTP::Server::Context, exception : Exception) : ExceptionPage
      report = if exception.is_a?(Response::Error)
                 exception.exception_report(context)
               else
                 Report.build(exception, context, context.response.status_code)
               end
      new(report)
    end

    def render : String
      @view = IO::Memory.new
      content
      @view.to_s
    end

    def to_s(io : IO) : Nil
      io << render
    end

    private def stored? : Bool
      !@occurrence.nil?
    end

    private def content : Nil
      raw "<!DOCTYPE html>"
      html lang: "en" do
        head do
          meta charset: "utf-8"
          meta name: "viewport", content: "width=device-width, initial-scale=1"
          meta name: "color-scheme", content: "dark light"
          meta name: "robots", content: "noindex"
          title "#{report.exception_class} · #{report.request.line}"
          link rel: "icon", href: "data:,"
          style { raw STYLES; raw PAGE_STYLES }
          noscript { style { raw ".azx .azd-panel { display: block; } .azx [data-action] { display: none; }" } }
        end
        body class: "azd azx" do
          script { raw THEME_BOOT }
          raw ICONS
          a "Skip to content", href: "#azx-main", class: "azd-skip"
          render_header
          # Two columns on wide screens (the exception beside its details), stacked below `page.css`'s breakpoint.
          main id: "azx-main", class: "azx-main", tabindex: "-1" do
            render_hero
            div class: "azx-details" do
              render_tabs
            end
          end
          div id: "azd-toast", class: "azd-toast", role: "status", aria_live: "polite"
          script { raw SCRIPT }
        end
      end
    end

    # ---------- header ----------

    private def render_header : Nil
      header class: "azd-top" do
        a href: ExceptionPage.dashboard_path || "/", class: "azd-brand" do
          icon "gem"
          text "Azu"
          span "Dev", class: "azd-brand-tag"
        end
        span Azu.current_config.env.to_s.downcase, class: "azd-chip azd-env"
        render_breadcrumb
        div class: "azd-actions azx-actions" do
          button type: "button", class: "azd-btn", data_action: "copy", data_copy: report.to_markdown, aria_label: "Copy as Markdown" do
            icon "copy"
            span "Copy as Markdown", class: "azd-btn-label"
          end
          dashboard_link
          button type: "button", class: "azd-icon-btn", data_action: "theme", aria_label: "Switch theme" do
            icon "sun", "azd-sun"
            icon "moon", "azd-moon"
          end
        end
      end
    end

    private def render_breadcrumb : Nil
      return unless stored? && (path = ExceptionPage.dashboard_path)

      nav class: "azx-crumbs", aria_label: "Breadcrumb" do
        ol do
          li { a "Dashboard", href: path }
          li { a "Errors", href: "#{path}#errors" }
          li { span report.exception_class.split("::").last, aria_current: "page" }
        end
      end
    end

    private def dashboard_link : Nil
      if stored?
        ExceptionPage.dashboard_path.try { |path| link_button "All errors", "#{path}#errors", "logs" }
      elsif url = report.dashboard_url
        link_button "Open in dashboard", url, "overview"
      end
    end

    private def link_button(label : String, href : String, icon_name : String) : Nil
      a href: href, class: "azd-btn" do
        icon icon_name
        span label, class: "azd-btn-label"
      end
    end

    # ---------- hero: what, where, why ----------

    private def render_hero : Nil
      section class: "azd-card azx-hero", aria_labelledby: "azx-title" do
        render_meta
        paragraph report.exception_class, class: "azx-class"
        h1 report.message, id: "azx-title", class: "azx-message"
        render_where
        render_hints
        report.location.try { |frame| frame.excerpt.try { |excerpt| render_excerpt(frame, excerpt) } }
      end
    end

    private def render_meta : Nil
      div class: "azx-meta" do
        badge Status.http(report.status), "#{report.status} #{report.status_text}"
        verb_chip report.request.method
        code report.request.path, class: "azx-path"
        report.request.route.try { |route| span route, class: "azd-chip azx-route", title: "Endpoint" }
        report.request.elapsed_ms.try { |millis| span "failed after #{Format.ms(millis)}", class: "azx-dim" }
        render_occurrence
        time Format.clock(report.timestamp), datetime: report.timestamp.to_rfc3339, class: "azx-dim azx-time"
      end
    end

    private def render_occurrence : Nil
      occurrence.try do |seen|
        path = ExceptionPage.dashboard_path || ""
        span class: "azx-occurrence" do
          seen.previous_id.try { |id| a "‹", href: "#{path}/errors/#{id}", class: "azx-step", aria_label: "Previous occurrence" }
          text "Occurrence #{seen.index} of #{seen.total}"
          seen.next_id.try { |id| a "›", href: "#{path}/errors/#{id}", class: "azx-step", aria_label: "Next occurrence" }
        end
      end
    end

    private def render_where : Nil
      paragraph(class: "azx-where") do
        if frame = report.location
          text frame.app? ? "Raised in " : "Raised in #{frame.kind.label.downcase} at "
          frame_link frame
          frame.method.try { |name| span " · #{name}", class: "azx-dim" }
          copy_button "location", frame.location
        else
          text "The backtrace has no location"
        end
      end
    end

    private def frame_link(frame : Frame) : Nil
      if url = frame.editor_url
        a frame.location, href: url, class: "azx-file", title: "Open in your editor"
      else
        code frame.location, class: "azx-file"
      end
    end

    private def render_hints : Nil
      hints = report.hints
      return if hints.empty?

      section class: "azx-hints", aria_label: "Likely causes" do
        h2 "Likely cause#{"s" if hints.size > 1}", class: "azx-label"
        ul do
          hints.first(MAX_HERO_HINTS).each { |hint| li { render_hint(hint) } }
        end
        if hints.size > MAX_HERO_HINTS
          details class: "azx-more" do
            summary "#{hints.size - MAX_HERO_HINTS} more"
            ul do
              hints[MAX_HERO_HINTS..].each { |hint| li { render_hint(hint) } }
            end
          end
        end
      end
    end

    private def render_hint(hint : Hint) : Nil
      div class: "azx-hint #{hint.tone.css}" do
        icon hint.tone.bad? || hint.tone.warn? ? "alert" : "check"
        div do
          paragraph(class: "azx-hint-title") { inline_code hint.title }
          paragraph(class: "azx-hint-detail") { inline_code hint.detail }
        end
      end
    end

    # Text with `backticked` spans set as code, the way hints name methods and settings.
    private def inline_code(content : String) : Nil
      content.split('`').each_with_index do |part, index|
        next if part.empty?
        index.odd? ? code(part) : text(part)
      end
    end

    private def render_excerpt(frame : Frame, excerpt : Excerpt) : Nil
      figure class: "azx-source" do
        tag("figcaption") do
          icon "routes"
          frame_link frame
        end
        div class: "azx-code", role: "region", aria_label: "Source of #{frame.location}", tabindex: "0" do
          excerpt.lines.each_with_index do |source, index|
            number = excerpt.start + index
            div class: number == excerpt.line ? "azx-line is-current" : "azx-line" do
              span number.to_s, class: "azx-ln", aria_hidden: "true"
              code source
            end
          end
        end
      end
    end

    # ---------- tabs ----------

    record TabSpec, id : String, label : String, icon : String, count : Int32

    private def tabs : Array(TabSpec)
      signals = report.panels.size
      [
        TabSpec.new("stack", "Stack", "tracing", report.app_frames.size),
        TabSpec.new("signals", "Signals", "overview", signals),
        TabSpec.new("request", "Request", "routes", 0),
        TabSpec.new("environment", "Environment", "config", 0),
      ]
    end

    private def render_tabs : Nil
      all = tabs
      div class: "azx-tablist", role: "tablist", aria_label: "Exception details" do
        all.each_with_index do |spec, index|
          selected = index.zero?
          button type: "button", role: "tab", id: "tab-#{spec.id}", class: "azd-tab", data_action: "tab", data_tab: spec.id,
            aria_controls: "panel-#{spec.id}", aria_selected: selected.to_s, tabindex: selected ? "0" : "-1" do
            icon spec.icon
            span spec.label, class: "azd-tab-label"
            span spec.count.zero? ? "" : spec.count.to_s, class: "azd-count"
          end
        end
      end
      all.each_with_index do |spec, index|
        section id: "panel-#{spec.id}", class: "azd-panel#{" is-active" if index.zero?}", role: "tabpanel", aria_labelledby: "tab-#{spec.id}", tabindex: "0" do
          case spec.id
          when "stack"   then render_stack
          when "signals" then render_signals
          when "request" then render_request
          else                render_environment
          end
        end
      end
    end

    # ---------- stack ----------

    private def render_stack : Nil
      if report.frames.empty?
        card "Backtrace", "tracing" do
          empty_state "No backtrace", "This error was answered without being raised, so there is no backtrace to show.", "tracing"
        end
      else
        div class: "azd-tree" do
          Frame::Kind.each do |kind|
            frames = report.frames.select { |frame| frame.kind == kind }
            next if frames.empty?
            details class: "azd-group", open: kind.app? || report.app_frames.empty? do
              summary do
                icon "chevron"
                text kind.label
                span frames.size.to_s, class: "azd-count"
              end
              ol class: "azx-frames" do
                frames.each { |frame| li { render_frame(frame) } }
              end
            end
          end
        end
      end
      render_causes
    end

    private def render_frame(frame : Frame) : Nil
      div class: "azx-frame" do
        span frame.method || "", class: "azx-frame-method"
        span class: "azx-frame-file" do
          frame.shard.try { |name| span name, class: "azd-chip" }
          frame.line ? frame_link(frame) : code(frame.raw)
        end
      end
    end

    private def render_causes : Nil
      return if report.causes.empty?

      card "Caused by", "alert", meta: report.causes.size.to_s do
        ol class: "azx-causes" do
          report.causes.each do |cause|
            li do
              paragraph cause.exception_class, class: "azx-class"
              paragraph cause.message
              cause.location.try { |frame| paragraph(class: "azx-dim") { text "at "; frame_link(frame) } }
            end
          end
        end
      end
    end

    # ---------- signals ----------

    private def render_signals : Nil
      if report.panels.empty?
        card "Signals", "overview" do
          empty_state "No signals were recorded around this request",
            "Require \"azu/dev\" with PERFORMANCE_MONITORING=true for the endpoint's history and the process memory, " \
            "and \"azu/cql\" with database instrumentation for the request's queries.", "overview"
        end
        return
      end

      div class: "azd-grid azx-signals" do
        report.panels.each { |panel| render_panel(panel) }
      end
    end

    private def render_panel(panel : Panel) : Nil
      card panel.title, panel.icon, meta: panel.note do
        unless panel.stats.empty?
          dl class: "azx-stats" do
            panel.stats.each do |stat|
              div class: "azx-stat #{stat.tone.css}" do
                dt stat.label
                dd stat.value
              end
            end
          end
        end
        unless panel.rows.empty?
          data_table "#{panel.title} details", panel.columns do
            panel.rows.each do |row|
              tr do
                row.each_with_index do |value, index|
                  td value, class: panel.columns[index]? == "SQL" ? "azd-mono azd-wrap azx-sql" : "azd-wrap"
                end
              end
            end
          end
        end
      end
    end

    # ---------- request ----------

    private def render_request : Nil
      request = report.request
      div class: "azd-grid azd-two" do
        card "Request", "routes" do
          facts do
            fact "Method", request.method
            fact "Path", request.path
            fact "Endpoint", request.route || "n/a"
            fact "Request ID", request.id || "n/a"
            fact "Elapsed", request.elapsed_ms.try { |millis| Format.ms(millis) } || "n/a"
            fact "Client", request.client || "n/a"
            fact "User agent", request.user_agent || "n/a"
            request.referer.try { |referer| fact "Referer", referer }
            report.error_id.try { |id| fact "Error ID", id }
          end
        end
        pairs_card "Query parameters", request.params
        pairs_card "Request headers", request.headers
        pairs_card "Request cookies", request.cookies
        pairs_card "Response headers", request.response_headers
        pairs_card "Response cookies", request.response_cookies
      end
    end

    private def pairs_card(title : String, pairs : Array({String, String})) : Nil
      card title, "logs", meta: pairs.empty? ? nil : pairs.size.to_s do
        if pairs.empty?
          paragraph "None", class: "azd-muted"
        else
          data_table title, ["Name", "Value"] do
            pairs.each do |name, value|
              tr do
                td name, class: "azd-mono"
                td value, class: "azd-mono azd-wrap"
              end
            end
          end
        end
      end
    end

    # ---------- environment ----------

    private def render_environment : Nil
      config = Azu.current_config
      div class: "azd-grid azd-two" do
        card "Runtime", "config" do
          facts do
            fact "Azu", Azu::VERSION
            fact "Crystal", Crystal::VERSION
            fact "Environment", config.env.to_s
            fact "Process", Process.pid.to_s
            fact "Working directory", Dir.current
            fact "Fingerprint", report.fingerprint
            fact "Recorded at", report.timestamp.to_rfc3339
          end
        end
        card "Environment variables", "config", meta: "redacted" do
          details class: "azx-env" do
            summary "Show #{CachedEnvironment.get.size} variables"
            data_table "Environment variables", ["Name", "Value"] do
              CachedEnvironment.get.to_a.sort_by!(&.[0]).each do |name, value|
                tr do
                  td name, class: "azd-mono"
                  td value, class: "azd-mono azd-wrap"
                end
              end
            end
          end
        end
      end
    end
  end
end

module Azu
  class ExceptionPage
    # The dashboard's answer for a report it no longer keeps, in the exception page's look.
    class Missing
      include Markup
      include Components::Dashboard::Widgets

      def initialize(@dashboard_path : String, @kept : Int32)
      end

      def render : String
        @view = IO::Memory.new
        raw "<!DOCTYPE html>"
        html lang: "en" do
          head do
            meta charset: "utf-8"
            meta name: "viewport", content: "width=device-width, initial-scale=1"
            meta name: "color-scheme", content: "dark light"
            title "Error not kept"
            link rel: "icon", href: "data:,"
            style { raw STYLES; raw PAGE_STYLES }
          end
          body class: "azd azx" do
            script { raw THEME_BOOT }
            raw ICONS
            header class: "azd-top" do
              a href: @dashboard_path, class: "azd-brand" do
                icon "gem"
                text "Azu"
                span "Dev", class: "azd-brand-tag"
              end
            end
            main class: "azx-main" do
              card "Errors", "alert" do
                empty_state "This error is no longer kept",
                  "The dashboard keeps the latest #{@kept} errors, and clearing it forgets them all.", "alert"
                a "See the errors it keeps", href: "#{@dashboard_path}#errors", class: "azd-link"
              end
            end
          end
        end
        @view.to_s
      end
    end
  end
end

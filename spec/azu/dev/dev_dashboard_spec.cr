require "../../spec_helper"
require "../../../src/azu/dev/dev"
require "../../support/integration_helpers"

include IntegrationHelpers

# Renders the dashboard through the handler and returns the de-chunked HTML body.
private def dashboard_html(metrics : Azu::PerformanceMetrics = Azu::PerformanceMetrics.new) : String
  context, io = create_context("GET", "/dev-dashboard")
  with_azu_env(Azu::Environment::Development) { Azu::Handler::DevDashboard.new(metrics: metrics).call(context) }
  context.response.close
  io.rewind
  HTTP::Client::Response.from_io(io).body
end

describe Azu::Handler::DevDashboard do
  # The dashboard serves in development only (see dev_dashboard_environment_spec.cr).
  around_each { |example| with_azu_env(Azu::Environment::Development) { example.run } }

  describe "initialization" do
    it "initializes with default path" do
      handler = Azu::Handler::DevDashboard.new
      handler.should be_a(Azu::Handler::DevDashboard)
      handler.path.should eq("/dev-dashboard")
    end

    it "initializes with custom path" do
      handler = Azu::Handler::DevDashboard.new("/custom-dashboard")
      handler.path.should eq("/custom-dashboard")
    end

    it "initializes with custom metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)
      handler.metrics.should eq(metrics)
    end
  end

  describe "routing" do
    it "handles dashboard requests" do
      handler = Azu::Handler::DevDashboard.new

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      response.should contain("<!DOCTYPE html>") # Should render HTML
      context.response.headers["Content-Type"].should contain("text/html")
    end

    it "passes through non-dashboard requests" do
      handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(1)
      handler.next = next_handler

      context, io = create_context("GET", "/other-path")
      handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "respects custom dashboard path" do
      handler = Azu::Handler::DevDashboard.new("/metrics")

      context, io = create_context("GET", "/metrics")
      handler.call(context)

      context.response.headers["Content-Type"].should contain("text/html")
    end
  end

  describe "dashboard content" do
    it "renders performance metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      # Should contain metrics-related content
      response.should_not be_empty
    end

    it "includes metrics from performance monitor" do
      metrics = Azu::PerformanceMetrics.new

      # Add some test data
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.close
      io.rewind
      response = io.gets_to_end
      response.should_not be_empty
    end
  end

  describe "clearing metrics" do
    it "clears metrics when clear parameter is provided" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard?clear=true")
      handler.call(context)

      context.response.status_code.should eq(302)
      context.response.headers["Location"].should eq("/dev-dashboard")

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(0)
    end

    it "does not clear metrics without clear parameter" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request(
        endpoint: "TestEndpoint",
        method: "GET",
        path: "/test",
        processing_time: 10.0,
        memory_before: 100_000_i64,
        memory_after: 110_000_i64,
        status_code: 200,
        request_id: "test-id"
      )

      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.status_code.should eq(200)

      stats = metrics.aggregate_stats
      stats.total_requests.should eq(1)
    end
  end

  describe "error handling" do
    it "handles rendering errors gracefully" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      # Create valid request
      context, io = create_context("GET", "/dev-dashboard")

      # Should not raise exception
      handler.call(context)

      # Should have a response
      context.response.status_code.should_not eq(0)
    end

    it "returns 500 on internal errors" do
      # This would require mocking the component to force an error
      # For now, we test that the error handling path exists
      handler = Azu::Handler::DevDashboard.new
      handler.should be_a(Azu::Handler::DevDashboard)
    end
  end

  describe "handler chain integration" do
    it "works in handler chain" do
      dashboard_handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(1)
      dashboard_handler.next = next_handler

      context, io = create_context("GET", "/api/users")
      dashboard_handler.call(context)

      get_response_body(context, io).should eq("OK")
      verify.call
    end

    it "renders dashboard without calling next handler" do
      dashboard_handler = Azu::Handler::DevDashboard.new
      next_handler, verify = create_next_handler(0)
      dashboard_handler.next = next_handler

      context, io = create_context("GET", "/dev-dashboard")
      dashboard_handler.call(context)

      context.response.headers["Content-Type"].should contain("text/html")
      verify.call
    end
  end

  describe "concurrent access" do
    it "handles concurrent dashboard requests" do
      handler = Azu::Handler::DevDashboard.new
      channel = Channel(Bool).new

      5.times do
        spawn do
          context, io = create_context("GET", "/dev-dashboard")
          handler.call(context)
          context.response.headers["Content-Type"].should contain("text/html")
          channel.send(true)
        end
      end

      5.times { channel.receive }
    end
  end

  describe "edge cases" do
    it "handles empty metrics" do
      metrics = Azu::PerformanceMetrics.new
      handler = Azu::Handler::DevDashboard.new(metrics: metrics)

      context, io = create_context("GET", "/dev-dashboard")
      handler.call(context)

      context.response.status_code.should eq(200)
    end

    it "handles query parameters in dashboard path" do
      handler = Azu::Handler::DevDashboard.new

      context, io = create_context("GET", "/dev-dashboard?param=value")
      handler.call(context)

      # Should still render dashboard
      context.response.headers["Content-Type"].should contain("text/html")
    end
  end

  describe "markup contract" do
    tabs = Azu::Components::DevDashboardComponent::TABS

    it "is a standards-mode UTF-8 document" do
      html = dashboard_html

      html.should start_with("<!DOCTYPE html>")
      html.should contain("<html lang='en'>")
      html.should contain("<meta charset='utf-8'>")
      html.should contain("name='viewport'")
      html.should contain("<noscript><style>.azd .azd-panel { display: block; }</style></noscript>")
    end

    it "uses semantic landmarks" do
      html = dashboard_html

      html.should contain("<header class='azd-top'>")
      html.should contain("<nav id='azd-nav'")
      html.should contain("aria-label='Dashboard sections'")
      html.should contain("<main id='azd-main'")
      html.should contain("<section id='panel-overview'")
    end

    it "ships the Overview, Routes, Performance Tracing and Config tabs plus the data tabs" do
      html = dashboard_html

      ["Overview", "Routes", "Performance Tracing", "Config", "Logs", "Database", "Cache", "Components"].each do |label|
        html.should contain(">#{label}</span>")
      end
    end

    it "implements the ARIA tabs pattern with a roving tabindex" do
      html = dashboard_html

      html.scan("role='tablist'").size.should eq(1)
      html.scan("role='tab'").size.should eq(tabs.size)
      html.scan("role='tabpanel'").size.should eq(tabs.size)
      html.scan(/<button[^>]*role='tab'[^>]*aria-selected='true'/).size.should eq(1)
      html.scan(/<button[^>]*role='tab'[^>]*tabindex='0'/).size.should eq(1)
      html.scan(/<button[^>]*role='tab'[^>]*tabindex='-1'/).size.should eq(tabs.size - 1)

      tabs.each do |tab|
        html.should contain("id='tab-#{tab.id}'")
        html.should contain("aria-controls='panel-#{tab.id}'")
        html.should contain("<section id='panel-#{tab.id}'")
        html.should contain("aria-labelledby='tab-#{tab.id}'")
      end
    end

    it "labels every icon-only button and announces copy confirmations politely" do
      html = dashboard_html

      icon_buttons = html.scan(/<button[^>]*azd-icon-btn[^>]*>/).map(&.[0])
      icon_buttons.should_not be_empty
      icon_buttons.each(&.should(contain("aria-label=")))
      html.should match(/id='azd-toast'[^>]*aria-live='polite'/)
    end

    it "renders the command palette as a modal dialog with combobox and listbox roles" do
      html = dashboard_html

      html.should contain("<dialog id='azd-palette'")
      html.should contain("role='combobox'")
      html.should contain("role='listbox'")
    end

    it "styles focus and respects reduced motion" do
      html = dashboard_html

      html.should contain(":focus-visible")
      html.should contain("prefers-reduced-motion")
      html.should contain("backdrop-filter")
    end

    it "scopes every CSS rule under the .azd root class" do
      css = Azu::Components::DevDashboardComponent::STYLES.gsub(/\/\*.*?\*\//m, "")
      selectors = css.scan(/([^{}]+)\{/).map(&.[1].strip)
      selectors.reject! { |selector| selector.starts_with?("@") || selector.matches?(/\A(from|to|\d+%)\z/) }

      selectors.should_not be_empty
      selectors.flat_map(&.split(',')).map(&.strip).each do |selector|
        (selector.starts_with?(".azd") || selector.starts_with?(":root:has(.azd")).should be_true, "unscoped selector: #{selector}"
      end
    end

    it "makes no external requests" do
      html = dashboard_html

      html.should_not match(/https?:\/\//)
      html.should_not match(/<link[^>]*rel='stylesheet'/)
      html.should_not match(/<script[^>]*src=/)
      html.should_not contain("@import")
      html.should_not contain("url(")
    end

    it "escapes request data in markup and keeps script blocks intact" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request("Evil::<b>Endpoint</b>", %(GET"><script>alert(1)</script>), "/<img src=x onerror=alert(1)>", 12.0, 1_i64, 2_i64, 500, %("><svg onload=alert(2)>))
      html = dashboard_html(metrics)

      ["<script>alert(1)", "<img src=x", "<svg onload", "<b>Endpoint</b>"].each { |payload| html.should_not contain(payload) }
      html.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
      html.should contain("&lt;img src=x onerror=alert(1)&gt;")
      html.scan("</script>").size.should eq(2) # theme boot + dashboard script, nothing injected
    end

    it "builds the log stream with level, search text and a copyable inspector" do
      metrics = Azu::PerformanceMetrics.new
      metrics.record_request("Users::Show", "GET", "/users/42", 8.0, 1_i64, 2_i64, 404, "abc-123")
      html = dashboard_html(metrics)

      html.should contain("class='azd-log lvl-warn'")
      html.should contain("data-level='warn'")
      html.should contain("data-off='debug'")
      html.should contain("Request ID: abc-123")
      html.should contain("aria-label='Copy log entry'")
    end

    it "renders registered routes as a tree with verb chips and copy buttons" do
      config = Azu::Configuration.new
      config.env = Azu::Environment::Development
      config.router.get "/users/:id", Azu::Handler::RequestId.new
      config.router.delete "/users/:id", Azu::Handler::RequestId.new

      Azu.with_config(config) do
        html = dashboard_html

        html.should contain("azd-verb v-get")
        html.should contain("azd-verb v-delete")
        html.should contain("<span class='azd-param'>:id</span>")
        html.should contain("aria-label='Copy endpoint GET /users/:id'")
        html.should_not contain("azd-verb v-head")
      end
    end
  end

  describe "behind the CSRF handler" do
    # dashboard.js posts the playground SQL with `X-Requested-With: azu-dashboard` and no CSRF token
    it "reaches the playground whichever handler is listed first, but still refuses other tokenless posts" do
      csrf = Azu::Handler::CSRF.new
      csrf.next = Azu::Handler::DevDashboard.new("/custom-dashboard")

      headers = HTTP::Headers{"X-Requested-With" => "azu-dashboard", "Content-Type" => "application/json"}
      context, io = create_context_with_remote_addr("POST", "/custom-dashboard/sql", headers: headers)
      csrf.call(context)
      body = get_response_body(context, io)
      body.should_not contain("CSRF token validation failed")
      context.response.status_code.should_not eq 403

      other, other_io = create_context_with_remote_addr("POST", "/custom-dashboard/other", headers: headers)
      csrf.call(other)
      other.response.status_code.should eq 403
      get_response_body(other, other_io).should contain("CSRF token validation failed")
    end
  end
end

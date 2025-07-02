require "http/server/handler"
require "../performance_metrics"
require "../performance_reporter"
require "../development_tools"
require "../cache"
require "../components/dev_dashboard_component"

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

        # Render dashboard using the component
        dashboard_component = Azu::Components::DevDashboardComponent.new(@metrics, @log)
        html_content = dashboard_component.render

        context.response.content_type = "text/html; charset=utf-8"
        context.response.print(html_content)
      rescue ex : Exception
        @log.error(exception: ex) { "Failed to render development dashboard" }
        context.response.status_code = 500
        context.response.content_type = "text/plain"
        context.response.print("Dashboard Error: #{ex.message}")
      end
    end
  end
end

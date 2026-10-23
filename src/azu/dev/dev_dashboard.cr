require "http/server/handler"
require "./performance_metrics"
require "./performance_reporter"
require "./development_tools"
require "../cache"
require "../handler/csrf"
require "./dev_dashboard_component"

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
      getter queries : QueryStore
      getter log : ::Log

      @start_time : Time

      def initialize(@path = DEFAULT_PATH, metrics : PerformanceMetrics? = nil, @log : ::Log = Azu::CONFIG.log, @queries : QueryStore = QueryStore.instance)
        @metrics = metrics || Azu::CONFIG.performance_monitor.try(&.metrics) || PerformanceMetrics.new
        @start_time = Time.utc
        CSRF.exempt("#{@path}/sql") # guarded by `run_playground` itself, and sent without a token by dashboard.js
      end

      def call(context : HTTP::Server::Context)
        case context.request.path
        when @path          then render_dashboard(context)
        when "#{@path}/sql" then run_playground(context)
        else
          call_next(context)
        end
      rescue ex : Exception
        @log.error(exception: ex) { "Failed to render development dashboard" }
        context.response.status_code = 500
        context.response.content_type = "text/plain"
        context.response.print("Dashboard Error: #{ex.message}")
      end

      private def render_dashboard(context : HTTP::Server::Context)
        # Handle clear metrics request
        if context.request.query_params["clear"]? == "true"
          @metrics.clear
          @queries.clear
          @log.info { "Development dashboard metrics cleared" }
          context.response.status_code = 302
          context.response.headers["Location"] = @path
          return
        end

        # Render dashboard using the component
        dashboard_component = Azu::Components::DevDashboardComponent.new(@metrics, @log, @start_time)
        html_content = dashboard_component.render

        context.response.content_type = "text/html; charset=utf-8"
        context.response.print(html_content)
      end

      PLAYGROUND_ROW_LIMIT =        200
      PLAYGROUND_MAX_BODY  = 10_000_i64

      # Read-only SQL playground: development env, loopback clients only, same-origin POST,
      # a single SELECT/WITH/EXPLAIN statement that is always rolled back.
      private def run_playground(context : HTTP::Server::Context)
        adapter = @queries.adapter
        unless adapter && playground_allowed?(context)
          return respond_json(context, 404, {error: "SQL playground is not available"})
        end
        unless context.request.method == "POST"
          return respond_json(context, 405, {error: "POST required"})
        end
        unless same_origin?(context.request)
          return respond_json(context, 403, {error: "Cross-origin request refused"})
        end

        body = context.request.body.try { |io| IO::Sized.new(io, PLAYGROUND_MAX_BODY).gets_to_end } || ""
        input = JSON.parse(body)
        sql = input["sql"]?.try(&.as_s?) || ""
        mode = input["mode"]?.try(&.as_s?) || "run"
        statement = QueryAnalysis.playground_sql(sql, mode, adapter.dialect)
        unless statement
          return respond_json(context, 400, {error: "Only a single read-only SELECT / WITH / EXPLAIN statement is allowed (EXPLAIN works on SELECT / WITH)."})
        end

        started = Time.instant
        columns, rows = adapter.read_only(statement, PLAYGROUND_ROW_LIMIT + 1)
        truncated = rows.size > PLAYGROUND_ROW_LIMIT
        result = SqlResult.new(columns, rows.first(PLAYGROUND_ROW_LIMIT), (Time.instant - started).total_milliseconds, truncated)
        context.response.content_type = "application/json"
        context.response.print(result.to_json)
      rescue ex : JSON::ParseException
        respond_json(context, 400, {error: "Invalid JSON body"})
      rescue ex
        respond_json(context, 422, {error: ex.message || ex.class.name})
      end

      private def playground_allowed?(context : HTTP::Server::Context) : Bool
        return false unless Azu::CONFIG.database.playground? && Azu::CONFIG.env.development?
        address = context.request.remote_address
        address.is_a?(Socket::IPAddress) && address.loopback?
      end

      private def same_origin?(request : HTTP::Request) : Bool
        return false unless request.headers["X-Requested-With"]? == "azu-dashboard"
        return true unless origin = request.headers["Origin"]?
        uri = URI.parse(origin)
        origin_host = uri.port ? "#{uri.host}:#{uri.port}" : uri.host
        origin_host.try(&.downcase) == request.headers["Host"]?.try(&.downcase)
      end

      private def respond_json(context : HTTP::Server::Context, status : Int32, payload) : Nil
        context.response.status_code = status
        context.response.content_type = "application/json"
        context.response.print(payload.to_json)
      end
    end
  end
end

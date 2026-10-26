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
    # It serves only in the development environment: in any other environment (judged on every request, by the
    # configuration of the app serving it) it hands the request to the next handler as if it were not in the chain, and
    # building one logs a warning (judged by the configuration current at construction, which is the global one
    # unless built inside `Azu.with_config`). There is no opt-in for production. Its SQL playground path is exempt from
    # CSRF checks in every environment; the exemption is inert while the dashboard passes requests on.
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
        # Guarded by `run_playground` itself, and sent without a token by dashboard.js. Registered whatever the
        # environment: the handler is built before the app that will serve it is known, and the exemption only matters
        # if the dashboard serves, which `call` allows in development only.
        CSRF.exempt("#{@path}/sql")
        unless serving?
          @log.warn { "Handler::DevDashboard was built in the #{Azu.current_config.env.to_s.downcase} environment: it only serves in development and passes every request on" }
        end
      end

      def call(context : HTTP::Server::Context)
        return call_next(context) unless serving?

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

      # The dashboard shows request data, SQL and configuration: development only, whatever the handler list says.
      private def serving? : Bool
        Azu.current_config.env.development?
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
        message = ex.message || ex.class.name
        respond_json(context, 422, {error: Azu.current_config.show_database_params? ? message : QueryAnalysis.redact_error(message)})
      end

      private def playground_allowed?(context : HTTP::Server::Context) : Bool
        return false unless Azu.current_config.database.playground? && serving?
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

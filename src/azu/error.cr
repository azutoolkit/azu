require "ecr"
require "exception_page"
require "json"
require "digest/sha1"

module Azu
  # Enhanced exception page with better debugging capabilities
  class ExceptionPage < ::ExceptionPage
    def styles : ExceptionPage::Styles
      ::ExceptionPage::Styles.new(
        accent: "red",
      )
    end
  end

  # Enhanced error context for better debugging
  struct ErrorContext
    getter timestamp : Time
    getter request_id : String?
    getter user_id : String?
    getter session_id : String?
    getter ip_address : String?
    getter user_agent : String?
    getter referer : String?
    getter endpoint : String?
    getter method : String?
    getter params : Hash(String, String)?
    getter headers : HTTP::Headers?
    getter environment : Hash(String, String)?

    def initialize(
      @timestamp = Time.utc,
      @request_id = nil,
      @user_id = nil,
      @session_id = nil,
      @ip_address = nil,
      @user_agent = nil,
      @referer = nil,
      @endpoint = nil,
      @method = nil,
      @params = nil,
      @headers = nil,
      @environment = nil,
    )
    end

    def self.from_http_context(context : HTTP::Server::Context, request_id : String? = nil)
      request = context.request

      new(
        timestamp: Time.utc,
        request_id: request_id || context.request.headers["X-Request-ID"]?,
        ip_address: request.remote_address.try(&.to_s),
        user_agent: request.headers["User-Agent"]?,
        referer: request.headers["Referer"]?,
        endpoint: request.path,
        method: request.method.to_s,
        params: request.query_params.to_h,
        headers: request.headers,
        environment: ENV.to_h
      )
    end

    def to_json(json : JSON::Builder)
      json.object do
        json.field "timestamp", timestamp.to_rfc3339
        json.field "request_id", request_id
        json.field "user_id", user_id
        json.field "session_id", session_id
        json.field "ip_address", ip_address
        json.field "user_agent", user_agent
        json.field "referer", referer
        json.field "endpoint", endpoint
        json.field "method", method
        json.field "params", params
        json.field "headers", headers.try(&.to_h)
        json.field "environment", environment
      end
    end

    def to_h
      {
        "timestamp"   => timestamp.to_rfc3339,
        "request_id"  => request_id,
        "user_id"     => user_id,
        "session_id"  => session_id,
        "ip_address"  => ip_address,
        "user_agent"  => user_agent,
        "referer"     => referer,
        "endpoint"    => endpoint,
        "method"      => method,
        "params"      => params,
        "headers"     => headers.try(&.to_h),
        "environment" => environment,
      }
    end
  end

  # Error aggregation and reporting system
  class ErrorReporter
    private getter errors : Array(ErrorReport) = [] of ErrorReport

    def report(error : Exception, context : ErrorContext? = nil, severity : Severity = Severity::ERROR)
      report = ErrorReport.new(error, context, severity)
      errors << report

      case severity
      when .debug?
        log.debug(exception: error) { format_error_message(report) }
      when .info?
        log.info(exception: error) { format_error_message(report) }
      when .warn?
        log.warn(exception: error) { format_error_message(report) }
      when .error?
        log.error(exception: error) { format_error_message(report) }
      when .fatal?
        log.fatal(exception: error) { format_error_message(report) }
      end

      # In production, you might want to send to external service
      send_to_external_service(report) if env.production?

      report
    end

    private def log : ::Log
      CONFIG.log
    end

    private def env : Environment
      CONFIG.env
    end

    def get_recent_errors(limit : Int32 = 100) : Array(ErrorReport)
      errors.last(limit)
    end

    def get_errors_by_type(error_type : String) : Array(ErrorReport)
      errors.select { |e| e.error_type == error_type }
    end

    def clear_errors
      errors.clear
    end

    enum Severity
      DEBUG
      INFO
      WARN
      ERROR
      FATAL
    end

    private def format_error_message(report : ErrorReport) : String
      String.build do |str|
        str << "[#{report.severity}] "
        str << "#{report.error_type}: #{report.message}"
        if context = report.context
          method = context.method || "UNKNOWN"
          endpoint = context.endpoint || "UNKNOWN"
          str << " | Request: #{method} #{endpoint}"
          str << " | IP: #{context.ip_address}" if context.ip_address
          str << " | Request ID: #{context.request_id}" if context.request_id
        end
      end
    end

    private def send_to_external_service(report : ErrorReport)
      # Placeholder for external error reporting service integration
      # Could integrate with Sentry, Rollbar, Bugsnag, etc.
    end
  end

  # Error report structure for aggregation
  struct ErrorReport
    getter id : String = Random::Secure.hex(16)
    getter timestamp : Time
    getter error_type : String
    getter message : String
    getter backtrace : Array(String)
    getter context : ErrorContext?
    getter severity : ErrorReporter::Severity
    getter fingerprint : String

    def initialize(error : Exception, @context = nil, @severity = ErrorReporter::Severity::ERROR)
      @timestamp = Time.utc
      @error_type = error.class.name
      @message = error.message || "Unknown error"
      @backtrace = error.backtrace || [] of String
      @fingerprint = generate_fingerprint(error)
    end

    def to_json(json : JSON::Builder)
      json.object do
        json.field "id", id
        json.field "timestamp", timestamp.to_rfc3339
        json.field "error_type", error_type
        json.field "message", message
        json.field "backtrace", backtrace
        json.field "context", context
        json.field "severity", severity.to_s
        json.field "fingerprint", fingerprint
      end
    end

    private def generate_fingerprint(error : Exception) : String
      # Create a fingerprint for grouping similar errors
      error_class = error.class.name
      error_message = error.message || "unknown"
      first_backtrace = error.backtrace.try(&.first) || "no_trace"

      content = "#{error_class}:#{error_message}:#{first_backtrace}"
      Digest::SHA1.hexdigest(content)[0..15]
    end
  end

  # Global error reporter instance
  ERROR_REPORTER = ErrorReporter.new
end

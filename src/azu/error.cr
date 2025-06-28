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

  # Cached environment data singleton for performance
  class CachedEnvironment
    private class_getter instance : CachedEnvironment = CachedEnvironment.new
    private getter _cached_env : Hash(String, String)?
    private getter _cache_time : Time?
    private getter _cache_ttl : Time::Span = 5.minutes

    def self.get : Hash(String, String)
      instance.get_environment
    end

    def self.refresh : Hash(String, String)
      instance.refresh_environment
    end

    def get_environment : Hash(String, String)
      now = Time.utc

      # Return cached environment if it's still valid
      if cached = @_cached_env
        if cache_time = @_cache_time
          return cached if (now - cache_time) < @_cache_ttl
        end
      end

      # Refresh cache
      refresh_environment
    end

    def refresh_environment : Hash(String, String)
      @_cached_env = ENV.to_h
      @_cache_time = Time.utc
      @_cached_env.not_nil!
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

    # Lazy-loaded environment data
    @_environment : Hash(String, String)?
    @_load_environment : Bool

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
      @_load_environment = false,
    )
    end

    # Lazy getter for environment data
    def environment : Hash(String, String)?
      return nil unless @_load_environment

      @_environment ||= CachedEnvironment.get
    end

    def self.from_http_context(context : HTTP::Server::Context, request_id : String? = nil, load_environment : Bool = true)
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
        _load_environment: load_environment
      )
    end

    # Create a lightweight context without environment data
    def self.lightweight_from_http_context(context : HTTP::Server::Context, request_id : String? = nil)
      from_http_context(context, request_id, load_environment: false)
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
    rescue
      ::Log.for("Azu::ErrorReporter")
    end

    private def env : Environment
      CONFIG.env
    rescue
      Environment::Development
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
      @error_type = error.class.to_s
      @message = begin
        msg = error.message
        msg.nil? ? "Unknown error" : msg
      rescue
        "Unknown error"
      end
      @backtrace = begin
        bt = error.backtrace
        bt.nil? ? [] of String : bt
      rescue
        [] of String
      end
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
      error_class = error.class.to_s
      error_message = error.message || "unknown"
      first_backtrace = "no_trace"

      begin
        if backtrace = error.backtrace
          if first_trace = backtrace.first?
            first_backtrace = first_trace
          end
        end
      rescue
        first_backtrace = "no_trace"
      end

      content = "#{error_class}:#{error_message}:#{first_backtrace}"
      Digest::SHA1.hexdigest(content)[0..15]
    end
  end

  # Global error reporter instance
  ERROR_REPORTER = ErrorReporter.new
end

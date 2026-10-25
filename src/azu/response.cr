require "http/status"
require "digest/sha1"
require "./error"
require "./templates"
require "./environment"

module Azu
  # A response is a message sent from a server to a client
  #
  # `Azu:Response` represents an interface for all Azu server responses. You can
  # still use Crystal `HTTP::Response` class to generete response messages.
  #
  # The response `#status` and `#headers` must be configured before writing the response body.
  # Once response output is written, changing the` #status` and `#headers` properties has no effect.
  #
  # ## Defining Responses
  #
  #
  # ```
  # module MyApp
  #   class Home::Page
  #     include Response::Html
  #
  #     TEMPLATE_PATH = "home/index.jinja"
  #
  #     def html
  #       render TEMPLATE_PATH, assigns
  #     end
  #
  #     def assigns
  #       {
  #         "welcome" => "Hello World!",
  #       }
  #     end
  #   end
  # end
  # ```
  module Response
    abstract def render

    # Writes this response to the connection; a response that is more than a string overrides it
    # (`Negotiable` picks a format, `Stream` and `EventStream` keep the connection open).
    def write_to(context : HTTP::Server::Context) : Nil
      context.response << render
    end

    class Empty
      include Response

      def render; end
    end

    # Enhanced base error class with better context and debugging
    class Error < Exception
      include Azu::Response

      property status : HTTP::Status = HTTP::Status::INTERNAL_SERVER_ERROR
      property title : String = "Internal Server Error"
      property detail : String = "Internal Server Error"
      property source : String = ""
      property errors : Array(String) = [] of String
      property context : ErrorContext?
      property error_id : String = Random::Secure.hex(16)
      property fingerprint : String

      private def templates : Templates
        Azu.current_config.templates
      end

      private def env : Environment
        Azu.current_config.env
      end

      private def log : ::Log
        Azu.current_config.log
      end

      # Request context (headers, params, process environment) and backtraces are
      # only meant for developers; they must never reach a client elsewhere.
      private def debug_context : ErrorContext?
        context if env.development?
      end

      private def debug_backtrace : String?
        inspect_with_backtrace if env.development?
      end

      def initialize(@detail = "", @source = "", @errors = Array(String).new, @context = nil)
        @fingerprint = generate_fingerprint
      end

      def initialize(@title, @status, @errors, @context = nil, cause : Exception? = nil)
        super(@title, cause)
        @detail = @title
        @fingerprint = generate_fingerprint
      end

      # Only `Response::Error`s carry messages meant for clients. What any other exception says
      # ("password authentication failed for user x") reaches a client in development only.
      def self.from_exception(ex, status = 500, context : ErrorContext? = nil)
        http_status = HTTP::Status.from_value(status)
        developer = Azu.current_config.env.development?
        error = new(
          developer ? (ex.message || "Error") : http_status.description.to_s,
          http_status,
          [] of String,
          context,
          ex
        )
        error.detail = developer ? ex.cause.to_s : error.title
        error
      end

      def link
        "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status_code}"
      end

      def html(context)
        return ExceptionPage.new(context, self).to_s if env.development?
        html
      end

      def html
        template_name = env.development? ? "error_debug.html" : "error.html"
        render template_name, {
          status:      status_code,
          link:        link,
          title:       title,
          detail:      detail,
          source:      source,
          errors:      errors,
          backtrace:   debug_backtrace,
          error_id:    error_id,
          fingerprint: fingerprint,
          context:     debug_context.try(&.to_h),
          timestamp:   Time.utc.to_rfc3339,
        }
      end

      def status_code
        status.value
      end

      def render(template : String, data)
        templates.load(template).render(data)
      end

      def xml
        messages = errors.map { |e| "<message>#{e}</message>" }.join("")
        context_xml = debug_context.try { |ctx| build_context_xml(ctx) } || ""
        backtrace_xml = debug_backtrace.try { |trace| "<backtrace>#{trace}</backtrace>" } || ""

        <<-XML
      <?xml version="1.0" encoding="UTF-8"?>
      <error title="#{title}" status="#{status_code}" link="#{link}" id="#{error_id}">
        <detail>#{detail}</detail>
        <source>#{source}</source>
        <fingerprint>#{fingerprint}</fingerprint>
        <errors>#{messages}</errors>
        #{context_xml}
        #{backtrace_xml}
      </error>
      XML
      end

      # RFC 7807 problem details (`application/problem+json`), the shape `ValidationError` uses with its
      # `errors` as a list of messages. `instance` is the request path when the error knows it. The request
      # context and backtrace are added in development only. `error_format = Legacy` keeps the pre-0.6 body.
      def json
        return legacy_json if Azu.current_config.error_format.legacy?

        problem = {
          "type"     => JSON::Any.new("about:blank"),
          "title"    => JSON::Any.new(title),
          "status"   => JSON::Any.new(status_code.to_i64),
          "detail"   => JSON::Any.new(detail),
          "errors"   => JSON::Any.new(errors.map { |message| JSON::Any.new(message) }),
          "error_id" => JSON::Any.new(error_id),
        }
        problem["instance"] = JSON::Any.new(source) unless source.empty?
        debug_context.try { |ctx| problem["context"] = JSON.parse(ctx.to_h.to_json) }
        debug_backtrace.try { |trace| problem["backtrace"] = JSON::Any.new(trace) }
        problem.to_json
      end

      private def legacy_json : String
        {
          Status:      status,
          Link:        link,
          Title:       title,
          Detail:      detail,
          Source:      source,
          Errors:      errors,
          ErrorId:     error_id,
          Fingerprint: fingerprint,
          Context:     debug_context.try(&.to_h),
          Backtrace:   debug_backtrace,
          Timestamp:   Time.utc.to_rfc3339,
        }.to_json
      end

      def text
        context_info = debug_context.try { |ctx| format_context_text(ctx) } || "Context: None"

        <<-TEXT
    Status: #{status_code}
    Link: #{link}
    Title: #{title}
    Detail: #{detail}
    Source: #{source}
    Error ID: #{error_id}
    Fingerprint: #{fingerprint}
    #{context_info}
    Errors: #{errors}
    Backtrace: #{debug_backtrace || "hidden"}
    Timestamp: #{Time.utc.to_rfc3339}
    TEXT
      end

      def render
      end

      def json_content_type : String
        Azu.current_config.error_format.legacy? ? "application/json" : "application/problem+json"
      end

      def to_s(context : HTTP::Server::Context)
        context.response.status_code = status_code
        context.response.headers["X-Error-ID"] = error_id
        context.response.headers["X-Error-Fingerprint"] = fingerprint

        content = if accept = context.request.accept
                    accept.first?.try do |accept_type|
                      if sub_type = accept_type.sub_type
                        case sub_type
                        when .includes?("html")
                          context.response.content_type = "text/html"
                          html(context)
                        when .includes?("json")
                          context.response.content_type = json_content_type
                          json
                        when .includes?("xml")
                          context.response.content_type = "application/xml"
                          xml
                        when .includes?("plain")
                          context.response.content_type = "text/plain"
                          text
                        else
                          context.response.content_type = "text/plain"
                          text
                        end
                      else
                        context.response.content_type = "text/plain"
                        text
                      end
                    end
                  end

        # Fallback to text if no accept header or no match
        unless content
          context.response.content_type = "text/plain"
          content = text
        end

        context.response.print content
      end

      private def generate_fingerprint : String
        error_class = self.class.name
        error_title = title || "unknown_title"
        error_detail = detail || "unknown_detail"
        error_source = source || "unknown_source"

        content = "#{error_class}:#{error_title}:#{error_detail}:#{error_source}"
        Digest::SHA1.hexdigest(content)[0..15]
      end

      private def report_error
        ERROR_REPORTER.report(self, context, ErrorReporter::Severity::ERROR)
      end

      private def build_context_xml(ctx : ErrorContext) : String
        String.build do |xml|
          xml << "<context>"
          xml << "<request_id>#{ctx.request_id}</request_id>" if ctx.request_id
          xml << "<endpoint>#{ctx.endpoint}</endpoint>" if ctx.endpoint
          xml << "<method>#{ctx.method}</method>" if ctx.method
          xml << "<ip_address>#{ctx.ip_address}</ip_address>" if ctx.ip_address
          xml << "<user_agent>#{ctx.user_agent}</user_agent>" if ctx.user_agent
          xml << "<timestamp>#{ctx.timestamp.to_rfc3339}</timestamp>"
          xml << "</context>"
        end
      end

      private def format_context_text(ctx : ErrorContext) : String
        String.build do |str|
          str << "Context:\n"
          str << "  Request ID: #{ctx.request_id}\n" if ctx.request_id
          str << "  Endpoint: #{ctx.method} #{ctx.endpoint}\n" if ctx.endpoint && ctx.method
          str << "  IP Address: #{ctx.ip_address}\n" if ctx.ip_address
          str << "  User Agent: #{ctx.user_agent}\n" if ctx.user_agent
          str << "  Timestamp: #{ctx.timestamp.to_rfc3339}\n"
        end
      end
    end

    # Validation-specific error with detailed field errors
    class ValidationError < Error
      getter field_errors : Hash(String, Array(String)) = Hash(String, Array(String)).new

      def initialize(@field_errors, context : ErrorContext? = nil)
        messages = [] of String
        @field_errors.each do |field, field_msgs|
          field_msgs.each do |msg|
            messages << "#{field}: #{msg}"
          end
        end
        super(
          title: "Validation Error",
          status: HTTP::Status::UNPROCESSABLE_ENTITY,
          errors: messages,
          context: context
        )
        @detail = "The request could not be processed due to validation errors."
        @source = ""
      end

      def initialize(field : String, message : String, context : ErrorContext? = nil)
        @field_errors = {field => [message]}
        super(
          title: "Validation Error",
          status: HTTP::Status::UNPROCESSABLE_ENTITY,
          errors: [message],
          context: context
        )
        @detail = "The field '#{field}' #{message}"
        @source = ""
      end

      def add_field_error(field : String, message : String)
        @field_errors[field] ||= [] of String
        @field_errors[field] << message
        @errors = build_error_messages
      end

      # RFC 7807 problem details, unless the app asks for the legacy body.
      def json
        return legacy_json if Azu.current_config.error_format.legacy?

        {type: "about:blank", title: title, status: status_code, detail: detail, errors: field_errors}.to_json
      end

      private def legacy_json : String
        {
          Status:      status,
          Title:       title,
          Detail:      detail,
          FieldErrors: field_errors,
          ErrorId:     error_id,
          Fingerprint: fingerprint,
          Context:     context.try(&.to_h),
          Timestamp:   Time.utc.to_rfc3339,
        }.to_json
      end

      private def build_error_messages : Array(String)
        messages = [] of String
        field_errors.each do |field, field_msgs|
          field_msgs.each do |msg|
            messages << "#{field}: #{msg}"
          end
        end
        messages
      end
    end

    # Authentication-related errors
    class AuthenticationError < Error
      def initialize(message = "Authentication required", context : ErrorContext? = nil)
        super(
          title: "Authentication Required",
          status: HTTP::Status::UNAUTHORIZED,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    class AuthorizationError < Error
      def initialize(message = "Insufficient permissions", context : ErrorContext? = nil)
        super(
          title: "Authorization Failed",
          status: HTTP::Status::FORBIDDEN,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    # Rate limiting error
    class RateLimitError < Error
      getter retry_after : Int32?

      def initialize(@retry_after = nil, context : ErrorContext? = nil)
        detail_msg = retry_after ? "Rate limit exceeded. Retry after #{retry_after} seconds." : "Rate limit exceeded."
        super(
          title: "Rate Limit Exceeded",
          status: HTTP::Status::TOO_MANY_REQUESTS,
          errors: [] of String,
          context: context
        )
        @detail = detail_msg
        @source = ""
      end

      def to_s(context : HTTP::Server::Context)
        context.response.headers["Retry-After"] = retry_after.to_s if retry_after
        super
      end
    end

    # Database-related errors
    class DatabaseError < Error
      def initialize(message = "Database operation failed", context : ErrorContext? = nil)
        super(
          title: "Database Error",
          status: HTTP::Status::INTERNAL_SERVER_ERROR,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    # External service errors
    class ExternalServiceError < Error
      getter service_name : String?

      def initialize(@service_name = nil, message = "External service unavailable", context : ErrorContext? = nil)
        super(
          title: service_name ? "#{service_name} Service Error" : "External Service Error",
          status: HTTP::Status::BAD_GATEWAY,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    # Timeout errors
    class TimeoutError < Error
      def initialize(message = "Request timeout", context : ErrorContext? = nil)
        super(
          title: "Request Timeout",
          status: HTTP::Status::REQUEST_TIMEOUT,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    # Legacy error classes for backward compatibility
    class Forbidden < AuthorizationError
      def initialize(context : ErrorContext? = nil)
        super("The server understood the request but refuses to authorize it.", context)
      end
    end

    class BadRequest < Error
      def initialize(message = "The server cannot or will not process the request due to something that is perceived to be a client error.", context : ErrorContext? = nil)
        super(
          title: "Bad Request",
          status: HTTP::Status::BAD_REQUEST,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    class PayloadTooLarge < Error
      def initialize(message = "The request body is larger than the server is willing to process.", context : ErrorContext? = nil)
        super(
          title: "Payload Too Large",
          status: HTTP::Status::PAYLOAD_TOO_LARGE,
          errors: [] of String,
          context: context
        )
        @detail = message
        @source = ""
      end
    end

    class NotFound < Error
      def initialize(path : String, context : ErrorContext? = nil)
        super(
          title: "Not Found",
          status: HTTP::Status::NOT_FOUND,
          errors: [] of String,
          context: context
        )
        @detail = "The server can't find the requested resource."
        @source = path
      end

      def render(template : String, data)
        templates.load("#{template}").render(data)
      end
    end
  end
end

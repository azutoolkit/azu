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
        CONFIG.templates
      end

      private def env : Environment
        CONFIG.env
      end

      private def log : ::Log
        CONFIG.log
      end

      def initialize(@detail = "", @source = "", @errors = Array(String).new, @context = nil)
        @fingerprint = generate_fingerprint
      end

      def initialize(@title, @status, @errors, @context = nil)
        @detail = @title
        @fingerprint = generate_fingerprint
      end

      def self.from_exception(ex, status = 500, context : ErrorContext? = nil)
        error = new(
          ex.message || "Error",
          HTTP::Status.from_value(status),
          [] of String,
          context
        )
        error.detail = ex.cause.to_s || "A server error occurred"
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
          backtrace:   inspect_with_backtrace,
          error_id:    error_id,
          fingerprint: fingerprint,
          context:     context,
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
        context_xml = context ? build_context_xml(context.as(ErrorContext)) : ""

        <<-XML
      <?xml version="1.0" encoding="UTF-8"?>
      <error title="#{title}" status="#{status_code}" link="#{link}" id="#{error_id}">
        <detail>#{detail}</detail>
        <source>#{source}</source>
        <fingerprint>#{fingerprint}</fingerprint>
        <errors>#{messages}</errors>
        #{context_xml}
        <backtrace>#{inspect_with_backtrace}</backtrace>
      </error>
      XML
      end

      def json
        context_data = context ? context.try(&.to_h) : nil

        {
          Status:      status,
          Link:        link,
          Title:       title,
          Detail:      detail,
          Source:      source,
          Errors:      errors,
          ErrorId:     error_id,
          Fingerprint: fingerprint,
          Context:     context_data,
          Backtrace:   inspect_with_backtrace,
          Timestamp:   Time.utc.to_rfc3339,
        }.to_json
      end

      def text
        context_info = context ? format_context_text(context.as(ErrorContext)) : "Context: None"

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
    Backtrace: #{inspect_with_backtrace}
    Timestamp: #{Time.utc.to_rfc3339}
    TEXT
      end

      def render
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
                          context.response.content_type = "application/json"
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

      def json
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

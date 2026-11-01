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
      property code : String = "internal_server_error"
      property details : JSON::Any? = nil
      property headers : HTTP::Headers = HTTP::Headers.new
      property source : String = ""
      property errors : Array(String) = [] of String
      property context : ErrorContext?
      property error_id : String = Random::Secure.hex(16)
      property fingerprint : String
      # The request path, set when the error is written for a request; the problem `instance`.
      property instance : String?
      @report : ExceptionPage::Report?

      DEFAULT_CODES = {
        400 => "bad_request",
        401 => "unauthorized",
        403 => "forbidden",
        404 => "not_found",
        405 => "method_not_allowed",
        408 => "request_timeout",
        409 => "conflict",
        413 => "payload_too_large",
        415 => "unsupported_media_type",
        422 => "validation_failed",
        426 => "upgrade_required",
        429 => "too_many_requests",
        500 => "internal_server_error",
        502 => "bad_gateway",
        503 => "service_unavailable",
      }

      # Default machine-readable error code for a given HTTP status.
      def self.default_code(status : HTTP::Status) : String
        DEFAULT_CODES[status.value]? || status.to_s.underscore
      end

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

      # The triage of this error (what was raised, where, the likely causes, the signals around it) for `context`:
      # built once, then shared by the exception page, the JSON body and the dev dashboard.
      def exception_report(context : HTTP::Server::Context) : ExceptionPage::Report
        @report ||= ExceptionPage::Report.build(self, context, status_code, error_id)
      end

      # The report while it may reach the client: in development only, like the context and the backtrace.
      private def debug_report : ExceptionPage::Report?
        @report if env.development?
      end

      def initialize(@detail = "", @source = "", @errors = Array(String).new, @context = nil, *, code : String? = nil, @details : JSON::Any? = nil)
        @code = code || Error.default_code(@status)
        @fingerprint = generate_fingerprint
      end

      def initialize(@title, @status, @errors = [] of String, @context = nil, cause : Exception? = nil, *, code : String? = nil, @details : JSON::Any? = nil, detail : String? = nil, @source : String = "")
        super(@title, cause)
        @detail = detail || @title
        @code = code || Error.default_code(@status)
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
          ex,
          code: default_code(http_status)
        )
        error.detail = developer ? ex.cause.to_s : error.title
        error
      end

      def link
        "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/#{status_code}"
      end

      def html(context)
        return ExceptionPage.new(exception_report(context)).render if env.development?
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

      # An `error.html` of the app that fails to render must not take the error handler down: the built-in page is used.
      def render(template : String, data)
        templates.render(template, data)
      rescue ex : Crinja::Error | Crinja::TemplateNotFoundError
        templates.builtin_fallback(template, ex).render(data)
      end

      def xml
        messages = errors.map { |e| "<message>#{HTML.escape(e)}</message>" }.join("")
        context_xml = debug_context.try { |ctx| build_context_xml(ctx) } || ""
        backtrace_xml = debug_backtrace.try { |trace| "<backtrace>#{HTML.escape(trace)}</backtrace>" } || ""

        <<-XML
      <?xml version="1.0" encoding="UTF-8"?>
      <error title="#{HTML.escape(title)}" status="#{status_code}" link="#{HTML.escape(link)}" id="#{HTML.escape(error_id)}">
        <detail>#{HTML.escape(detail)}</detail>
        <source>#{HTML.escape(source)}</source>
        <fingerprint>#{fingerprint}</fingerprint>
        <errors>#{messages}</errors>
        #{context_xml}
        #{backtrace_xml}
      </error>
      XML
      end

      # RFC 7807 problem details, the shape `ValidationError` uses with its `errors` as a list of messages.
      # `title` is the error's own title (not always the status phrase: `type` is `about:blank`, so read the
      # status), `instance` is the request path once the error is written for a request. The request context and
      # backtrace are added in development only. `error_format = Legacy` keeps the pre-0.6 body, and
      # `error_format = Envelope` renders the structured JSON error envelope.
      def json(http_context : HTTP::Server::Context? = nil)
        config = Azu.current_config
        return legacy_json if config.error_format.legacy?
        return envelope_json(http_context) if config.error_format.envelope?

        problem = {
          "type"     => JSON::Any.new("about:blank"),
          "title"    => JSON::Any.new(title),
          "status"   => JSON::Any.new(status_code.to_i64),
          "detail"   => JSON::Any.new(detail),
          "errors"   => JSON::Any.new(errors.map { |message| JSON::Any.new(message) }),
          "error_id" => JSON::Any.new(error_id),
        }
        instance.try { |path| problem["instance"] = JSON::Any.new(path) }
        debug_context.try { |ctx| problem["context"] = JSON.parse(ctx.to_h.to_json) }
        debug_backtrace.try { |trace| problem["backtrace"] = JSON::Any.new(trace) }
        debug_report.try { |report| problem["exception"] = JSON.parse(report.to_json) }
        problem.to_json
      end

      # Renders the configurable JSON envelope (`code`, `message`, `details`, `request_id`).
      def envelope_json(http_context : HTTP::Server::Context? = nil) : String
        envelope_cfg = Azu.current_config.error_envelope
        req_id = resolve_request_id(http_context)
        payload = Hash(String, JSON::Any).new
        payload["code"] = JSON::Any.new(code)
        payload["message"] = JSON::Any.new(envelope_message)
        if det = envelope_details(envelope_cfg.validation_mode)
          payload["details"] = det
        else
          payload["details"] = JSON::Any.new(nil)
        end
        payload["request_id"] = req_id ? JSON::Any.new(req_id) : JSON::Any.new(nil)

        if wrapper = envelope_cfg.wrapper_key
          {wrapper => payload}.to_json
        else
          payload.to_json
        end
      end

      protected def envelope_message : String
        detail.presence || title
      end

      protected def envelope_details(mode : ValidationErrorMode) : JSON::Any?
        details
      end

      private def resolve_request_id(http_context : HTTP::Server::Context?) : String?
        RequestContext.current?.try(&.request_id) ||
          http_context.try { |ctx| ctx.response.headers["X-Request-ID"]? || ctx.request.headers["X-Request-ID"]? } ||
          context.try(&.request_id)
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
          Exception:   debug_report,
          Timestamp:   Time.utc.to_rfc3339,
        }.to_json
      end

      def text
        context_info = debug_context.try { |ctx| format_context_text(ctx) } || "Context: None"

        <<-TEXT
    #{debug_report.try { |report| format_triage_text(report) }}Status: #{status_code}
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

      # `application/problem+json` only for a client whose Accept header names it; any other JSON client gets the
      # same body as `application/json`. `error_format = Legacy` and `error_format = Envelope` never send problem+json.
      def json_content_type(problem : Bool = false) : String
        fmt = Azu.current_config.error_format
        problem && fmt.problem? ? "application/problem+json" : "application/json"
      end

      # True when the request's Accept header asks for `problem+json` at least as eagerly as for plain JSON
      # (`Negotiation.prefers_problem?`).
      def self.accepts_problem?(context : HTTP::Server::Context) : Bool
        Negotiation.prefers_problem?(context.request.headers["Accept"]?)
      end

      # Applies any error-specific protocol headers (`Allow`, `Retry-After`, `WWW-Authenticate`, `Accept`, `Upgrade`, etc.).
      protected def apply_headers(context : HTTP::Server::Context) : Nil
        headers.each do |name, values|
          values.each_with_index do |val, idx|
            if idx == 0
              context.response.headers[name] = val
            else
              context.response.headers.add(name, val)
            end
          end
        end
      end

      def to_s(context : HTTP::Server::Context)
        config = Azu.current_config
        exception_report(context) if env.development?
        context.response.status_code = status_code
        context.response.headers["X-Error-ID"] = error_id
        context.response.headers["X-Error-Fingerprint"] = fingerprint
        apply_headers(context)
        @instance ||= context.request.path

        if custom = config.error_renderer
          custom.call(context, self)
          return nil
        end

        content = negotiate_error_content(context, config) || fallback_error_content(context, config)
        context.response.print content
      end

      private def negotiate_error_content(context : HTTP::Server::Context, config : Configuration) : String?
        accept_type = context.request.accept.try(&.first?) || return nil
        sub_type = accept_type.sub_type || return plain_error_content(context)

        case sub_type
        when .includes?("html")
          context.response.content_type = "text/html"
          html(context)
        when .includes?("json")
          context.response.content_type = json_content_type(Error.accepts_problem?(context))
          json(context)
        when .includes?("xml")
          context.response.content_type = "application/xml"
          xml
        when "*"
          fallback_error_content(context, config)
        else
          plain_error_content(context)
        end
      end

      private def fallback_error_content(context : HTTP::Server::Context, config : Configuration) : String
        if config.error_format.envelope?
          context.response.content_type = "application/json"
          json(context)
        else
          plain_error_content(context)
        end
      end

      private def plain_error_content(context : HTTP::Server::Context) : String
        context.response.content_type = "text/plain"
        text
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
          xml << "<request_id>#{HTML.escape(ctx.request_id.to_s)}</request_id>" if ctx.request_id
          xml << "<endpoint>#{HTML.escape(ctx.endpoint.to_s)}</endpoint>" if ctx.endpoint
          xml << "<method>#{HTML.escape(ctx.method.to_s)}</method>" if ctx.method
          xml << "<ip_address>#{HTML.escape(ctx.ip_address.to_s)}</ip_address>" if ctx.ip_address
          xml << "<user_agent>#{HTML.escape(ctx.user_agent.to_s)}</user_agent>" if ctx.user_agent
          xml << "<timestamp>#{ctx.timestamp.to_rfc3339}</timestamp>"
          xml << "</context>"
        end
      end

      private def format_triage_text(report : ExceptionPage::Report) : String
        String.build do |str|
          str << report.exception_class << ": " << report.message << '\n'
          report.location.try { |frame| str << "Raised in: " << frame.location << '\n' }
          report.hints.first(3).each { |hint| str << "Likely cause: " << hint.title << '\n' }
          report.dashboard_url.try { |url| str << "Details: " << url << '\n' }
          str << '\n'
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

    # Validation-specific error with detailed field errors (422 Unprocessable Entity)
    class ValidationError < Error
      DEFAULT_DETAIL = "The request could not be processed due to validation errors."

      getter field_errors : Hash(String, Array(String)) = Hash(String, Array(String)).new
      @custom_detail : Bool = false

      def initialize(@field_errors, context : ErrorContext? = nil, *, code : String = "validation_failed", message : String? = nil)
        messages = [] of String
        @field_errors.each do |field, field_msgs|
          field_msgs.each do |msg|
            messages << (field.empty? || field == "base" ? msg : "#{field}: #{msg}")
          end
        end
        super(
          title: "Validation Error",
          status: HTTP::Status::UNPROCESSABLE_ENTITY,
          errors: messages,
          context: context,
          code: code
        )
        if message
          @detail = message
          @custom_detail = true
        else
          @detail = DEFAULT_DETAIL
        end
        @source = ""
      end

      def initialize(field : String, message : String, context : ErrorContext? = nil, *, code : String = "validation_failed")
        @field_errors = {field => [message]}
        super(
          title: "Validation Error",
          status: HTTP::Status::UNPROCESSABLE_ENTITY,
          errors: [message],
          context: context,
          code: code
        )
        @detail = field.empty? || field == "base" ? message : "The field '#{field}' #{message}"
        @custom_detail = field.empty? || field == "base"
        @source = ""
      end

      def initialize(message : String, context : ErrorContext? = nil, *, code : String = "validation_failed", details : JSON::Any? = nil)
        @field_errors = {} of String => Array(String)
        super(
          title: "Validation Error",
          status: HTTP::Status::UNPROCESSABLE_ENTITY,
          errors: [message],
          context: context,
          code: code,
          details: details
        )
        @detail = message
        @custom_detail = true
        @source = ""
      end

      def add_field_error(field : String, message : String)
        @field_errors[field] ||= [] of String
        @field_errors[field] << message
        @errors = build_error_messages
      end

      protected def envelope_message : String
        mode = Azu.current_config.error_envelope.validation_mode
        if mode.first_message_only? && !@custom_detail
          if first_entry = @field_errors.first?
            field, msgs = first_entry
            if first_msg = msgs.first?
              return field.empty? || field == "base" ? first_msg : "#{field}: #{first_msg}"
            end
          end
        end
        detail.presence || title
      end

      protected def envelope_details(mode : ValidationErrorMode) : JSON::Any?
        return details if @field_errors.empty?

        if mode.first_message_only?
          first_map = Hash(String, JSON::Any).new
          @field_errors.each do |field, msgs|
            if first = msgs.first?
              first_map[field] = JSON::Any.new(first)
            end
          end
          JSON::Any.new(first_map)
        else
          all_map = Hash(String, JSON::Any).new
          @field_errors.each do |field, msgs|
            all_map[field] = JSON::Any.new(msgs.map { |msg| JSON::Any.new(msg) })
          end
          JSON::Any.new(all_map)
        end
      end

      # RFC 7807 problem details, unless the app asks for the legacy or envelope body.
      def json(http_context : HTTP::Server::Context? = nil)
        config = Azu.current_config
        return legacy_json if config.error_format.legacy?
        return envelope_json(http_context) if config.error_format.envelope?

        rendered_errors = if config.error_envelope.validation_mode.first_message_only?
                            @field_errors.transform_values { |msgs| msgs.first? ? [msgs.first] : [] of String }
                          else
                            @field_errors
                          end
        problem = {type: "about:blank", title: title, status: status_code, detail: envelope_message, errors: rendered_errors}
        (path = instance) ? problem.merge(instance: path).to_json : problem.to_json
      end

      private def legacy_json : String
        {
          Status:      status,
          Title:       title,
          Detail:      detail,
          FieldErrors: field_errors,
          ErrorId:     error_id,
          Fingerprint: fingerprint,
          Context:     debug_context.try(&.to_h), # the request's headers and address: development only
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

    alias UnprocessableEntity = ValidationError

    # Authentication-related errors (401 Unauthorized)
    class AuthenticationError < Error
      property www_authenticate : String?

      def initialize(message = "Authentication required", context : ErrorContext? = nil, *, code : String = "unauthorized", @www_authenticate : String? = "Bearer", details : JSON::Any? = nil)
        super("Authentication Required", HTTP::Status::UNAUTHORIZED, context: context, code: code, details: details, detail: message)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        if (scheme = @www_authenticate) && !context.response.headers.has_key?("WWW-Authenticate")
          context.response.headers["WWW-Authenticate"] = scheme
        end
      end
    end

    alias Unauthorized = AuthenticationError

    # Authorization-related errors (403 Forbidden)
    class AuthorizationError < Error
      def initialize(message = "Insufficient permissions", context : ErrorContext? = nil, *, code : String = "forbidden", details : JSON::Any? = nil)
        super("Authorization Failed", HTTP::Status::FORBIDDEN, context: context, code: code, details: details, detail: message)
      end
    end

    # Rate limiting error (429 Too Many Requests)
    class RateLimitError < Error
      getter retry_after : Int32?

      def initialize(@retry_after = nil, context : ErrorContext? = nil, *, message : String? = nil, code : String = "too_many_requests", details : JSON::Any? = nil)
        detail_msg = message || (retry_after ? "Rate limit exceeded. Retry after #{retry_after} seconds." : "Rate limit exceeded.")
        super("Rate Limit Exceeded", HTTP::Status::TOO_MANY_REQUESTS, context: context, code: code, details: details, detail: detail_msg)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        context.response.headers["Retry-After"] = retry_after.to_s if retry_after
      end

      # Every rate limit error has the title it is built with, so one fingerprint: hashed once, not per refusal.
      private def generate_fingerprint : String
        return super unless self.class == RateLimitError
        @@fingerprint ||= super
      end

      @@fingerprint : String?
    end

    alias TooManyRequests = RateLimitError

    # Database-related errors
    class DatabaseError < Error
      def initialize(message = "Database operation failed", context : ErrorContext? = nil, *, code : String = "database_error")
        super("Database Error", HTTP::Status::INTERNAL_SERVER_ERROR, context: context, code: code, detail: message)
      end
    end

    # External service errors
    class ExternalServiceError < Error
      getter service_name : String?

      def initialize(@service_name = nil, message = "External service unavailable", context : ErrorContext? = nil, *, code : String = "bad_gateway")
        title = service_name ? "#{service_name} Service Error" : "External Service Error"
        super(title, HTTP::Status::BAD_GATEWAY, context: context, code: code, detail: message)
      end
    end

    # Timeout errors
    class TimeoutError < Error
      def initialize(message = "Request timeout", context : ErrorContext? = nil, *, code : String = "request_timeout")
        super("Request Timeout", HTTP::Status::REQUEST_TIMEOUT, context: context, code: code, detail: message)
      end
    end

    # Legacy and standard error classes
    class Forbidden < AuthorizationError
      def initialize(message = "The server understood the request but refuses to authorize it.", context : ErrorContext? = nil, *, code : String = "forbidden", details : JSON::Any? = nil)
        super(message, context, code: code, details: details)
      end

      def initialize(context : ErrorContext?)
        super("The server understood the request but refuses to authorize it.", context)
      end
    end

    class BadRequest < Error
      def initialize(message = "The server cannot or will not process the request due to something that is perceived to be a client error.", context : ErrorContext? = nil, *, code : String = "bad_request", details : JSON::Any? = nil)
        super("Bad Request", HTTP::Status::BAD_REQUEST, context: context, code: code, details: details, detail: message)
      end
    end

    class Conflict < Error
      def initialize(message = "The request could not be completed due to a conflict with the current state of the target resource.", context : ErrorContext? = nil, *, code : String = "conflict", details : JSON::Any? = nil)
        super("Conflict", HTTP::Status::CONFLICT, context: context, code: code, details: details, detail: message)
      end
    end

    class PayloadTooLarge < Error
      # A size rejection can leave an unread body. Crystal closes that connection
      # instead of draining attacker-controlled input; tell keep-alive clients to
      # reconnect rather than advertising a connection the server will discard.
      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        context.response.headers["Connection"] = "close"
      end

      def initialize(message = "The request body is larger than the server is willing to process.", context : ErrorContext? = nil, *, code : String = "payload_too_large", details : JSON::Any? = nil)
        super("Payload Too Large", HTTP::Status::PAYLOAD_TOO_LARGE, context: context, code: code, details: details, detail: message)
      end
    end

    class NotFound < Error
      def initialize(path : String = "", context : ErrorContext? = nil, *, message : String = "The server can't find the requested resource.", code : String = "not_found", details : JSON::Any? = nil)
        super("Not Found", HTTP::Status::NOT_FOUND, context: context, code: code, details: details, detail: message, source: path)
      end
    end

    # 405 Method Not Allowed with required `Allow` header.
    class MethodNotAllowed < Error
      getter allow : Array(String)

      def initialize(method : String, path : String, @allow : Array(String), context : ErrorContext? = nil, *, message : String? = nil, code : String = "method_not_allowed", details : JSON::Any? = nil)
        super("Method Not Allowed", HTTP::Status::METHOD_NOT_ALLOWED, context: context, code: code, details: details, detail: message || "Method #{method} is not allowed for #{path}.", source: path)
      end

      def initialize(@allow : Array(String), message : String = "The method specified in the request is not allowed for the resource identified by the request URI.", context : ErrorContext? = nil, *, code : String = "method_not_allowed", details : JSON::Any? = nil)
        super("Method Not Allowed", HTTP::Status::METHOD_NOT_ALLOWED, context: context, code: code, details: details, detail: message)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        context.response.headers["Allow"] = @allow.join(", ") unless @allow.empty?
      end
    end

    # 415 Unsupported Media Type with `Accept` and `Accept-Post` headers.
    class UnsupportedMediaType < Error
      getter accept : Array(String)?

      def initialize(message = "The request entity has a media type which the server or resource does not support.", @accept : Array(String)? = nil, context : ErrorContext? = nil, *, code : String = "unsupported_media_type", details : JSON::Any? = nil)
        super("Unsupported Media Type", HTTP::Status::UNSUPPORTED_MEDIA_TYPE, context: context, code: code, details: details, detail: message)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        if (types = @accept) && !types.empty?
          joined = types.join(", ")
          context.response.headers["Accept"] ||= joined
          context.response.headers["Accept-Post"] ||= joined
        end
      end
    end

    # 426 Upgrade Required with `Upgrade` header.
    class UpgradeRequired < Error
      getter upgrade : String?

      def initialize(message = "The server refuses to perform the request using the current protocol but might be willing to do so after the client upgrades to a different protocol.", @upgrade : String? = nil, context : ErrorContext? = nil, *, code : String = "upgrade_required", details : JSON::Any? = nil)
        super("Upgrade Required", HTTP::Status::UPGRADE_REQUIRED, context: context, code: code, details: details, detail: message)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        if proto = @upgrade
          context.response.headers["Upgrade"] = proto
          context.response.headers["Connection"] ||= "Upgrade"
        end
      end
    end

    # 503 Service Unavailable with optional `Retry-After` header.
    class ServiceUnavailable < Error
      getter retry_after : Int32?

      def initialize(message = "The server is currently unable to handle the request due to a temporary overload or scheduled maintenance.", @retry_after : Int32? = nil, context : ErrorContext? = nil, *, code : String = "service_unavailable", details : JSON::Any? = nil)
        super("Service Unavailable", HTTP::Status::SERVICE_UNAVAILABLE, context: context, code: code, details: details, detail: message)
      end

      protected def apply_headers(context : HTTP::Server::Context) : Nil
        super
        context.response.headers["Retry-After"] = @retry_after.to_s if @retry_after
      end
    end
  end
end

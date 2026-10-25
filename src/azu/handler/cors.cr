module Azu
  module Handler
    module Headers
      VARY              = "Vary"
      ORIGIN            = "Origin"
      X_ORIGIN          = "X-Origin"
      REQUEST_METHOD    = "Access-Control-Request-Method"
      REQUEST_HEADERS   = "Access-Control-Request-Headers"
      ALLOW_EXPOSE      = "Access-Control-Expose-Headers"
      ALLOW_ORIGIN      = "Access-Control-Allow-Origin"
      ALLOW_METHODS     = "Access-Control-Allow-Methods"
      ALLOW_HEADERS     = "Access-Control-Allow-Headers"
      ALLOW_CREDENTIALS = "Access-Control-Allow-Credentials"
      ALLOW_MAX_AGE     = "Access-Control-Max-Age"
    end

    class CORS
      include HTTP::Handler

      alias OriginType = Array(String | Regex)
      FORBIDDEN     = "Forbidden for invalid origins, methods or headers"
      ALLOW_METHODS = %w(POST PUT PATCH DELETE)
      ALLOW_HEADERS = %w(Accept Content-Type)
      # SECURITY: Empty by default - origins must be explicitly configured
      # Previously was ["*", /./] which allowed all origins
      DEFAULT_ORIGINS = [] of (String | Regex)

      property origins, headers, methods, credentials, max_age
      @origin : Origin

      def initialize(
        origins : OriginType? = nil,
        @methods = ALLOW_METHODS,
        @headers = ALLOW_HEADERS,
        @credentials = false,
        @max_age : Int32? = 0,
        @expose_headers : Array(String)? = nil,
        @vary : String? = nil,
      )
        @origins = if origins
                     origins.map { |origin| origin.as(String | Regex) }.as(OriginType)
                   else
                     DEFAULT_ORIGINS
                   end
        @origin = Origin.new(@origins)
      end

      def call(context : HTTP::Server::Context)
        unless request_origin = @origin.of(context.request)
          # The answer depends on the Origin header even when it is absent: a cache must not hand this one to a request with one.
          add_vary(context.response.headers, [Headers::ORIGIN]) unless @origin.any?
          return call_next(context)
        end

        if @origin.match?(request_origin)
          is_preflight_request = preflight?(context)
          put_expose_header(context.response)
          # A refused preflight is already answered and closed: nothing more is granted on it.
          return if is_preflight_request && !Preflight.process(context, self)

          put_response_headers(context.response, request_origin)
          call_next(context) unless is_preflight_request
        else
          forbidden(context)
        end
      end

      def forbidden(context)
        # A refusal grants nothing: drop whatever Access-Control-* header was already set for the request.
        context.response.headers.map { |name, _| name }.each { |name| context.response.headers.delete(name) if name.downcase.starts_with?("access-control-") }
        add_vary(context.response.headers, [Headers::ORIGIN])
        error = Response::Forbidden.new
        LogText.log_refusal(Log.for("Azu::Handler::CORS"), context.request, error, client: true)
        error.to_s(context)
        context.response.close
      end

      private def put_expose_header(response)
        response.headers[Headers::ALLOW_EXPOSE] = @expose_headers.as(Array).join(",") if @expose_headers
      end

      private def put_response_headers(response, request_origin : String)
        response.headers[Headers::ALLOW_CREDENTIALS] = @credentials.to_s if @credentials
        response.headers[Headers::ALLOW_ORIGIN] = request_origin
        add_vary(response.headers, vary) unless @origin.any?
      end

      private def vary : Array(String)
        [Headers::ORIGIN] + (@vary || "").split(',').map(&.strip).reject(&.empty?)
      end

      # Joins the fields to a `Vary` the response already has; written as the one value `Origin,Field` when it has none.
      private def add_vary(headers : HTTP::Headers, fields : Array(String)) : Nil
        return if headers[Headers::VARY]? == "*"

        if headers.has_key?(Headers::VARY)
          fields.each { |field| headers.add(Headers::VARY, field) unless headers.includes_word?(Headers::VARY, field) }
        else
          headers[Headers::VARY] = fields.join(",")
        end
      end

      private def preflight?(context)
        context.request.method == "OPTIONS"
      end
    end

    module Preflight
      extend self

      # Answers the preflight: false when it was refused (a closed 403), true when its allow headers were written.
      def process(context, cors) : Bool
        unless valid?(context, cors)
          cors.forbidden(context)
          return false
        end

        put_preflight_headers(context.request, context.response, cors.max_age)
        true
      end

      def valid?(context, cors)
        valid_method?(context.request, cors.methods) &&
          valid_headers?(context.request, cors.headers)
      end

      def put_preflight_headers(request, response, max_age)
        response.headers[Headers::ALLOW_METHODS] = request.headers[Headers::REQUEST_METHOD]
        response.headers[Headers::ALLOW_HEADERS] = request.headers[Headers::REQUEST_HEADERS]
        response.headers[Headers::ALLOW_MAX_AGE] = max_age.to_s if max_age
        response.content_length = 0
        response.flush
      end

      def valid_method?(request, methods)
        methods.includes? request.headers[Headers::REQUEST_METHOD]?
      end

      def valid_headers?(request, headers)
        request_headers = request.headers[Headers::REQUEST_HEADERS]?
        return false if request_headers.nil? || request_headers.empty?

        headers.any? do |header|
          request_headers.downcase.split(',').includes? header.downcase
        end
      end
    end

    # Stateless: one instance serves every request, so the origin of a request is passed around, never kept.
    struct Origin
      getter origins : CORS::OriginType

      def initialize(@origins : CORS::OriginType)
      end

      def match?(request_origin : String)
        return false if @origins.empty?
        return true if any?

        @origins.any? do |origin|
          case origin
          when String then origin == request_origin
          when Regex  then origin =~ request_origin
          end
        end
      end

      def any?
        @origins.includes? "*"
      end

      def of(request) : String?
        request.headers[Headers::ORIGIN]? || request.headers[Headers::X_ORIGIN]?
      end
    end
  end
end

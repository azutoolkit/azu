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

      property headers, methods, max_age
      @origins : OriginType

      # A copy: the origins are changed with `origins=` (which checks them), not by editing the array returned here.
      def origins : OriginType
        @origins.dup
      end

      getter? credentials : Bool
      @origin : Origin

      def initialize(
        origins : OriginType? = nil,
        @methods = ALLOW_METHODS,
        @headers = ALLOW_HEADERS,
        @credentials : Bool = false,
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
        ensure_not_wildcard_with_credentials!(@origin, @credentials)
      end

      # Kept for callers of the former `property credentials`.
      def credentials : Bool
        @credentials
      end

      def origins=(origins : OriginType) : OriginType
        origins = origins.dup
        origin = Origin.new(origins)
        ensure_not_wildcard_with_credentials!(origin, @credentials)
        @origin = origin
        @origins = origins
      end

      def credentials=(credentials : Bool) : Bool
        ensure_not_wildcard_with_credentials!(@origin, credentials)
        @credentials = credentials
      end

      # Browsers ignore `Access-Control-Allow-Origin: *` on a credentialed request, and echoing the request's origin
      # instead would let every site read the responses of a signed-in user: the combination is refused outright.
      private def ensure_not_wildcard_with_credentials!(origin : Origin, credentials : Bool) : Nil
        return unless credentials && origin.wildcard?
        raise ArgumentError.new("CORS: origins \"*\" cannot be combined with credentials: true (it would let any site read " \
                                "credentialed responses); list the allowed origins instead")
      end

      def call(context : HTTP::Server::Context)
        unless request_origin = @origin.of(context.request)
          # The answer depends on the Origin header even when it is absent: a cache must not hand this one to a request with one.
          Vary.add(context.response.headers, Headers::ORIGIN)
          return call_next(context)
        end

        if @origin.match?(request_origin)
          is_preflight_request = preflight?(context)
          # Set before a preflight is answered: its response is flushed, and what is set after that depends on how the
          # server writes headers. A refusal below removes all of it again.
          put_expose_header(context.response)
          put_response_headers(context.response, request_origin)
          # A refused preflight is already answered and closed: nothing more is granted on it.
          # The answer to a preflight also depends on what it asks for.
          Vary.add(context.response.headers, Headers::REQUEST_METHOD, Headers::REQUEST_HEADERS) if is_preflight_request
          return if is_preflight_request && !Preflight.process(context, self)

          call_next(context) unless is_preflight_request
        else
          forbidden(context)
        end
      end

      def forbidden(context)
        # A refusal grants nothing: drop whatever Access-Control-* header was already set for the request.
        context.response.headers.map { |name, _| name }.each { |name| context.response.headers.delete(name) if name.downcase.starts_with?("access-control-") }
        Vary.add(context.response.headers, Headers::ORIGIN)
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
        response.headers[Headers::ALLOW_ORIGIN] = allow_origin_value(request_origin)
        Vary.add(response.headers, [Headers::ORIGIN] + vary)
      end

      # A literal `*` for a public wildcard (never with credentials, which the constructor refuses), the request's own
      # origin otherwise.
      private def allow_origin_value(request_origin : String) : String
        @origin.wildcard? ? "*" : request_origin
      end

      private def vary : Array(String)
        (@vary || "").split(',').map(&.strip).reject(&.empty?)
      end

      # A preflight is an OPTIONS request that names the method it asks about (Fetch standard). Any other OPTIONS request
      # is an ordinary CORS request: the next handler answers it, with this origin's headers.
      private def preflight?(context)
        context.request.method == "OPTIONS" && context.request.headers.has_key?(Headers::REQUEST_METHOD)
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

        put_preflight_headers(context.request, context.response, cors.max_age, cors.headers)
        true
      end

      def valid?(context, cors)
        valid_method?(context.request, cors.methods) &&
          valid_headers?(context.request, cors.headers)
      end

      # *allowed*: the headers a preflight may ask for. They are sent as configured (not as the request spelled them);
      # without it the request's own list is echoed.
      def put_preflight_headers(request, response, max_age, allowed : Array(String)? = nil)
        response.headers[Headers::ALLOW_METHODS] = request.headers[Headers::REQUEST_METHOD]
        request.headers[Headers::REQUEST_HEADERS]?.try do |requested|
          response.headers[Headers::ALLOW_HEADERS] = allowed ? allowed_spelling(requested, allowed) : requested
        end
        response.headers[Headers::ALLOW_MAX_AGE] = max_age.to_s if max_age
        response.content_length = 0
        response.flush
      end

      # The requested headers, in the order asked and in the spelling of the allowed list.
      private def allowed_spelling(requested : String, allowed : Array(String)) : String
        spelled = allowed.to_h { |header| {header.downcase, header} }
        names = requested.split(',').compact_map { |header| spelled[header.strip.downcase]? }
        names.uniq!
        names.join(", ")
      end

      def valid_method?(request, methods)
        methods.includes? request.headers[Headers::REQUEST_METHOD]?
      end

      def valid_headers?(request, headers)
        # Nothing asked for, nothing to allow: a bare preflight (a DELETE with no custom header) is decided by method.
        return true unless request_headers = request.headers[Headers::REQUEST_HEADERS]?

        allowed = headers.map(&.downcase)
        requested = request_headers.split(',').map(&.strip.downcase).reject(&.empty?)
        # Every requested header must be allowed: one allowed header must not carry the others through.
        !requested.empty? && requested.all? { |header| allowed.includes?(header) }
      end
    end

    # Stateless: one instance serves every request, so the origin of a request is passed around, never kept.
    struct Origin
      getter origins : CORS::OriginType

      @patterns : CORS::OriginType

      # The regex that must match the whole Origin. In extended mode (`x`) the source may end in a `# comment`, which
      # would swallow the closing parenthesis: the line break ends it.
      private def anchored(regex : Regex) : Regex
        Regex.new("\\A(?:#{regex.source}#{"\n" if regex.options.extended?})\\z", regex.options)
      end

      def initialize(@origins : CORS::OriginType)
        @patterns = @origins.map { |origin| origin.is_a?(Regex) ? anchored(origin) : origin }
      end

      NULL_ORIGIN = "null"

      # Exact (case-sensitive: browsers serialize the scheme and host in lower case), never by prefix or suffix: a regex
      # must match the whole Origin (it is wrapped in `\A(?:...)\z`), so `/good\.com/` does not allow `https://good.com.evil.test`. An Origin
      # that is not `scheme://host[:port]` (a path, userinfo, a trailing slash, a comma-joined pair of Origin headers,
      # control characters) matches nothing, whatever the regexes say. `null` (sandboxed frames, `file:`, redirects across
      # origins) is any site's to send, so it matches only when it is listed as the string "null": not by `"*"`, not by a regex.
      def match?(request_origin : String) : Bool
        return false if @origins.empty? || !well_formed?(request_origin)
        return @origins.includes?(NULL_ORIGIN) if request_origin == NULL_ORIGIN
        return true if wildcard?

        @patterns.any? do |origin|
          case origin
          when String then origin == request_origin
          when Regex  then origin.matches?(request_origin)
          end
        end
      end

      private def well_formed?(origin : String) : Bool
        return true if origin == NULL_ORIGIN

        scheme, separator, authority = origin.partition("://")
        return false if separator.empty? || authority.empty? || !scheme.matches?(/\A[A-Za-z][A-Za-z0-9+.\-]*\z/)

        authority.each_char.all? { |char| char.ord > 0x20 && char.ord < 0x7f && !"/?#@,\\".includes?(char) }
      end

      def wildcard?
        @origins.includes? "*"
      end

      def of(request) : String?
        request.headers[Headers::ORIGIN]? || request.headers[Headers::X_ORIGIN]?
      end
    end
  end
end

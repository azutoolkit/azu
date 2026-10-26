require "random/secure"
require "crypto/subtle"
require "openssl/hmac"
require "http"
require "html"
require "base64"

module Azu
  module Handler
    # The CSRF Handler implements Cross-Site Request Forgery protection
    # following OWASP recommendations for token-based mitigation
    class CSRF
      include HTTP::Handler

      # HTTP methods that require CSRF protection
      UNSAFE_METHODS = %w(POST PUT PATCH DELETE)

      # Headers and parameters for CSRF tokens
      HEADER_KEY = "X-CSRF-TOKEN"
      PARAM_KEY  = "_csrf"
      COOKIE_KEY = "csrf_token"

      # Token configuration
      TOKEN_LENGTH       = 32
      HMAC_SECRET_LENGTH = 64

      # Cookie configuration
      COOKIE_MAX_AGE   = 86400 # 24 hours
      COOKIE_SAME_SITE = HTTP::Cookie::SameSite::Strict

      # CSRF protection strategy
      enum Strategy
        # Synchronizer Token Pattern - token stored in session/cookie, verified against form/header
        SynchronizerToken
        # Double Submit Cookie Pattern with HMAC signing (recommended)
        SignedDoubleSubmit
        # Simple Double Submit Cookie (not recommended, but available)
        DoubleSubmit
      end

      # Where the SynchronizerToken strategy keeps the token it compares a request against.
      abstract class TokenStore
        abstract def read(context : HTTP::Server::Context) : String?
        abstract def write(context : HTTP::Server::Context, token : String) : Nil
      end

      # The default: a cookie of the handler (`cookie_name`, `cookie_max_age`, ...). The client holds
      # the token, so this is not a synchronizer in the strict sense; prefer `SessionTokenStore`.
      class CookieTokenStore < TokenStore
        def initialize(@handler : CSRF)
        end

        def read(context : HTTP::Server::Context) : String?
          @handler.cookie_token(context)
        end

        def write(context : HTTP::Server::Context, token : String) : Nil
          @handler.set_token_cookie(context, token)
        end
      end

      # Keeps the token in the session, through `Azu.session_adapter` (`csrf_token` and
      # `store_csrf_token`). `Session::SessionHandler` must come before `CSRF` in the handler chain.
      #
      # A read that fails (no adapter, no session for this request) logs and answers no token, so a
      # state-changing request is refused with 403 instead of crashing; issuing a token still raises
      # (`SessionAdapter::NotConfigured` without an adapter), so a misconfiguration is not silent.
      class SessionTokenStore < TokenStore
        def read(context : HTTP::Server::Context) : String?
          adapter.csrf_token(context).presence
        rescue ex
          Log.for("Azu::Handler::CSRF").warn { "session CSRF token unavailable: #{ex.message}" }
          nil
        end

        def write(context : HTTP::Server::Context, token : String) : Nil
          adapter.store_csrf_token(context, token)
        end

        private def adapter : SessionAdapter
          Azu.session_adapter.try { |adapter| adapter if adapter.csrf? } || raise SessionAdapter::NotConfigured.new
        end
      end

      # How much of a multipart body is looked at for the token field: the token must be a field that comes before
      # the first file part and ends within these bytes. The rest of the body is not read here.
      MULTIPART_SCAN_LIMIT = 64 * 1024

      # The body is over `upload.max_file_size`: answered with 413, never buffered past the limit.
      private class BodyTooLarge < Exception
      end

      # Hands out the bytes the handler already read, then the rest of the request body, so the endpoint reads the
      # whole body as it was sent.
      class ReplayedBody < IO
        def initialize(prefix : Bytes, @rest : IO)
          @prefix = IO::Memory.new(prefix)
        end

        def read(slice : Bytes) : Int32
          return 0 if slice.empty?
          count = @prefix.read(slice)
          count > 0 ? count : @rest.read(slice)
        end

        def write(slice : Bytes) : NoReturn
          raise IO::Error.new("A replayed request body is read only")
        end

        def close : Nil
          @rest.close
          super
        end
      end

      # Instance-level configuration properties
      property strategy : Strategy
      @secret_key : String?
      property cookie_name : String
      property header_name : String
      property param_name : String
      property cookie_max_age : Int32
      property cookie_same_site : HTTP::Cookie::SameSite
      property? secure_cookies : Bool
      # Used by the SynchronizerToken strategy; the cookie-based strategies always use their cookie.
      setter token_store : TokenStore?

      def token_store : TokenStore
        @token_store ||= CookieTokenStore.new(self)
      end

      # Default instance for backward compatibility
      @@default_instance : CSRF? = nil
      @@instance_mutex = Mutex.new
      @@shared_secret_key : String? = nil
      @@exempt_paths = Set(String).new

      # Exempts one exact path from the check, for an endpoint that protects itself another way
      # (the dev dashboard's SQL playground does: development only, loopback clients only, same
      # origin and a custom header). Order independent: it applies to every CSRF handler, wherever
      # it sits in the pipeline relative to the registering handler.
      def self.exempt(path : String) : Nil
        @@instance_mutex.synchronize { @@exempt_paths << path }
      end

      def self.exempt?(path : String) : Bool
        @@instance_mutex.synchronize { @@exempt_paths.includes?(path) }
      end

      # Exception for CSRF validation failures
      class InvalidTokenError < Exception
        def initialize(message = "Invalid CSRF token")
          super(message)
        end
      end

      def initialize(
        @skip_routes : Array(String) = [] of String,
        @strategy : Strategy = Strategy::SignedDoubleSubmit,
        secret_key : String? = nil,
        @cookie_name : String = COOKIE_KEY,
        @header_name : String = HEADER_KEY,
        @param_name : String = PARAM_KEY,
        @cookie_max_age : Int32 = COOKIE_MAX_AGE,
        @cookie_same_site : HTTP::Cookie::SameSite = COOKIE_SAME_SITE,
        @secure_cookies : Bool = true,
        @token_store : TokenStore? = nil,
        defer_secret : Bool = false,
      )
        key = secret_key
        key = @@shared_secret_key if key.nil? && @@shared_secret_key && !@@shared_secret_key.try(&.empty?)
        @secret_key = key.presence
        self.secret_key unless defer_secret
        @@in_use.set(true)
      end

      @@in_use = Atomic(Bool).new(false)

      # True once a CSRF handler has been built in this process (`new`, `default` or `configure`). Templates get
      # `csrf_token`, `csrf_tag` and `csrf_metatag` only then, so the pages of an app without CSRF protection set
      # no token cookie and need no `CSRF_SECRET`.
      def self.in_use? : Bool
        @@in_use.get
      end

      # The key tokens are signed with: the one given, else `CSRF_SECRET`. A key only this process knows breaks
      # every token after a restart and across instances, so without either it is a random per-process key (with
      # one warning) outside production, and `Azu::Env::MissingError` in production (see `Azu::Env.secret`).
      def secret_key : String
        @secret_key ||= Azu::Env.secret("CSRF_SECRET")
      end

      def secret_key=(value : String) : String
        @secret_key = value
      end

      # Get default instance (backward compatibility)
      # Uses double-checked locking to avoid mutex contention
      def self.default(defer_secret : Bool = false) : CSRF
        instance = @@default_instance
        return instance if instance

        @@instance_mutex.synchronize do
          @@default_instance ||= new(defer_secret: defer_secret)
        end
      end

      # Forgets the default instance, the shared secret and that a handler was built (for specs).
      def self.reset_default!
        @@instance_mutex.synchronize do
          @@default_instance = nil
          @@shared_secret_key = nil
          @@in_use.set(false)
        end
      end

      # Get or generate shared secret key
      protected def self.or_generate_shared_secret_key : String
        @@instance_mutex.synchronize do
          @@shared_secret_key ||= Random::Secure.urlsafe_base64(HMAC_SECRET_LENGTH)
        end
      end

      # Class-level methods for backward compatibility
      # These delegate to the default instance
      def self.token(context : HTTP::Server::Context) : String
        default.token(context)
      end

      def self.tag(context : HTTP::Server::Context) : String
        default.tag(context)
      end

      def self.metatag(context : HTTP::Server::Context) : String
        default.metatag(context)
      end

      def self.validate_origin(context : HTTP::Server::Context) : Bool
        default.validate_origin(context)
      end

      # Configuration helper methods
      def self.use_signed_double_submit!
        default.strategy = Strategy::SignedDoubleSubmit
      end

      def self.use_synchronizer_token!
        default.strategy = Strategy::SynchronizerToken
      end

      def self.use_double_submit!
        default.strategy = Strategy::DoubleSubmit
      end

      # Configuration block
      def self.configure(&)
        instance = default(defer_secret: true)
        result = yield instance
        instance.secret_key # the block may have set it; if not, a production app fails here, at boot
        result
      end

      # Class-level property accessors that delegate to default instance
      def self.strategy
        default.strategy
      end

      def self.strategy=(value : Strategy)
        default.strategy = value
      end

      def self.secret_key : String
        default.secret_key
      end

      def self.secret_key=(value : String)
        @@shared_secret_key = value
        default.secret_key = value
      end

      def self.cookie_name
        default.cookie_name
      end

      def self.cookie_name=(value : String)
        default.cookie_name = value
      end

      def self.header_name
        default.header_name
      end

      def self.header_name=(value : String)
        default.header_name = value
      end

      def self.param_name
        default.param_name
      end

      def self.param_name=(value : String)
        default.param_name = value
      end

      def self.cookie_max_age
        default.cookie_max_age
      end

      def self.cookie_max_age=(value : Int32)
        default.cookie_max_age = value
      end

      def self.secure_cookies
        default.secure_cookies
      end

      def self.secure_cookies=(value : Bool)
        default.secure_cookies = value
      end

      def call(context : HTTP::Server::Context)
        # Skip CSRF protection for safe methods
        if safe_method?(context.request.method)
          call_next(context)
          return
        end

        # Skip CSRF protection for configured routes
        if skip_route?(context.request.path)
          call_next(context)
          return
        end

        # Validate CSRF token (AJAX clients send it in the header)
        if valid_token?(context)
          call_next(context)
        else
          refuse(context, Response::AuthorizationError.new("CSRF token validation failed"))
        end
      rescue BodyTooLarge
        context.response.headers["Connection"] = "close" # the rest of the body is not read: do not wait for the next request in it
        refuse(context, Response::PayloadTooLarge.new)
      end

      # The refusal is written here, never raised to the `Rescuer`: this is where it is logged (the request headers are
      # not: they carry the cookies and credentials).
      private def refuse(context : HTTP::Server::Context, error : Response::Error) : Nil
        LogText.log_refusal(Log.for("Azu::Handler::CSRF"), context.request, error, client: true)
        error.to_s(context)
      end

      # Check if HTTP method is safe (doesn't require CSRF protection)
      private def safe_method?(method : String) : Bool
        !UNSAFE_METHODS.includes?(method.upcase)
      end

      # Check if route should skip CSRF protection
      private def skip_route?(path : String) : Bool
        CSRF.exempt?(path) || @skip_routes.any? { |route| path.starts_with?(route) }
      end

      # Validate CSRF token based on configured strategy
      def valid_token?(context : HTTP::Server::Context) : Bool
        case @strategy
        when .synchronizer_token?
          validate_synchronizer_token(context)
        when .signed_double_submit?
          validate_signed_double_submit(context)
        when .double_submit?
          validate_double_submit(context)
        else
          false
        end
      end

      # Generate CSRF token for forms/AJAX requests. Issuing one sets the token cookie, so a response that already
      # carries it gets that token again: another would replace the cookie and leave the token printed before stale.
      def token(context : HTTP::Server::Context) : String
        if issued = issued_token(context)
          return issued
        end

        case @strategy
        when .synchronizer_token?
          generate_synchronizer_token(context)
        when .signed_double_submit?
          generate_signed_double_submit_token(context)
        when .double_submit?
          generate_double_submit_token(context)
        else
          ""
        end
      end

      # Generate HTML hidden input with CSRF token
      def tag(context : HTTP::Server::Context) : String
        tag(token(context))
      end

      # The hidden input for `token_value`, a token already issued for this request.
      def tag(token_value : String) : String
        %Q(<input type="hidden" name="#{@param_name}" value="#{HTML.escape(token_value)}" />)
      end

      # Generate meta tag with CSRF token for AJAX requests
      def metatag(context : HTTP::Server::Context) : String
        metatag(token(context))
      end

      # The meta tag for `token_value`, a token already issued for this request.
      def metatag(token_value : String) : String
        %Q(<meta name="#{@param_name}" content="#{HTML.escape(token_value)}" />)
      end

      # SYNCHRONIZER TOKEN PATTERN
      # Token stored in session/cookie, compared with submitted token

      private def validate_synchronizer_token(context : HTTP::Server::Context) : Bool
        # No stored token, no match: the body is not read for a request that cannot pass.
        return false unless session_token = token_store.read(context)
        return false unless request_token = extract_token_from_request(context)

        # Constant-time comparison to prevent timing attacks
        Crypto::Subtle.constant_time_compare(request_token, session_token)
      end

      private def generate_synchronizer_token(context : HTTP::Server::Context) : String
        # Generate or retrieve existing token from the token store. A token cookie already on the response is one
        # `issued_token` did not reuse (deleted, expired, another path): the request's cookie it replaces is not handed out.
        replaced = token_store.is_a?(CookieTokenStore) && context.response.cookies.has_key?(@cookie_name)
        if !replaced && (existing_token = token_store.read(context))
          existing_token
        else
          new_token = Random::Secure.urlsafe_base64(TOKEN_LENGTH)
          token_store.write(context, new_token)
          new_token
        end
      end

      # SIGNED DOUBLE SUBMIT COOKIE PATTERN (RECOMMENDED)
      # Token is HMAC-signed with secret, cookie and form token must match

      private def validate_signed_double_submit(context : HTTP::Server::Context) : Bool
        return false unless cookie_token = extract_token_from_cookie(context)
        return false unless request_token = extract_token_from_request(context)

        # Both tokens must be identical
        return false unless Crypto::Subtle.constant_time_compare(request_token, cookie_token)

        # Verify HMAC signature
        verify_hmac_token(request_token)
      end

      private def generate_signed_double_submit_token(context : HTTP::Server::Context) : String
        # Generate base token
        base_token = Random::Secure.urlsafe_base64(TOKEN_LENGTH)
        timestamp = Clock.now.to_unix.to_s

        # Create HMAC signature
        data = "#{base_token}:#{timestamp}"
        signature = create_hmac_signature(data)

        # Combine into final token
        signed_token = "#{base_token}:#{timestamp}:#{signature}"

        # Set cookie with same token
        set_token_cookie(context, signed_token)

        signed_token
      end

      # DOUBLE SUBMIT COOKIE PATTERN (SIMPLE, NOT RECOMMENDED)
      # Token in cookie must match token in form/header

      private def validate_double_submit(context : HTTP::Server::Context) : Bool
        return false unless cookie_token = extract_token_from_cookie(context)
        return false unless request_token = extract_token_from_request(context)

        # Simple comparison (vulnerable to subdomain attacks)
        Crypto::Subtle.constant_time_compare(request_token, cookie_token)
      end

      private def generate_double_submit_token(context : HTTP::Server::Context) : String
        token = Random::Secure.urlsafe_base64(TOKEN_LENGTH)
        set_token_cookie(context, token)
        token
      end

      # HELPER METHODS

      # Extract CSRF token from request (header, form data, or query params)
      private def extract_token_from_request(context : HTTP::Server::Context) : String?
        # Try header first (for AJAX requests)
        if token = context.request.headers[@header_name]?
          return token
        end

        # Try form data for POST requests
        if context.request.method.upcase.in?(UNSAFE_METHODS)
          if token = extract_token_from_form(context)
            return token
          end
        end

        # Try query parameters (less secure, but sometimes needed)
        if token = context.request.query_params[@param_name]?
          return token
        end

        nil
      end

      # Extract token from form data. Only a body that carries the token in a form is read, and never past
      # `upload.max_file_size` (`BodyTooLarge`); the endpoint still gets the whole body afterwards.
      private def extract_token_from_form(context : HTTP::Server::Context) : String?
        content_type = context.request.headers["Content-Type"]?.try(&.downcase)
        return nil unless content_type
        return nil unless body = context.request.body

        if content_type.starts_with?("application/x-www-form-urlencoded")
          form_token(context, body)
        elsif content_type.starts_with?("multipart/form-data")
          multipart_token(context, body)
        end
      end

      private def form_token(context : HTTP::Server::Context, body : IO) : String?
        limit = Azu.current_config.upload.max_file_size
        raise BodyTooLarge.new if declared_length(context.request).try { |length| length > limit }

        buffer = IO::Memory.new
        IO.copy(IO::Sized.new(body, read_size: limit.to_i64 + 1), buffer)
        raise BodyTooLarge.new if buffer.size > limit

        bytes = buffer.to_slice
        context.request.body = IO::Memory.new(bytes)
        HTTP::Params.parse(String.new(bytes))[@param_name]?
      end

      private def multipart_token(context : HTTP::Server::Context, body : IO) : String?
        # No size check here: `upload.max_file_size` applies to each file of a multipart body, which the endpoint
        # enforces as it parses; this only looks at the first bytes.
        preamble = read_up_to(body, MULTIPART_SCAN_LIMIT)
        context.request.body = ReplayedBody.new(preamble, body)
        boundary = boundary_of(context.request.headers["Content-Type"]?) || return
        CSRF.multipart_field(preamble, boundary, @param_name)
      end

      private def declared_length(request : HTTP::Request) : UInt64?
        request.headers["Content-Length"]?.try(&.to_u64?)
      end

      private def read_up_to(io : IO, limit : Int32) : Bytes
        buffer = Bytes.new(limit)
        filled = 0
        while filled < limit
          count = io.read(buffer[filled, limit - filled])
          break if count == 0
          filled += count
        end
        buffer[0, filled]
      end

      private def boundary_of(content_type : String?) : String?
        return nil unless content_type
        MIME::MediaType.parse(content_type)["boundary"]?.try(&.presence)
      rescue MIME::Error
        nil
      end

      # The value of the multipart field *name* in *preamble* (the first bytes of a body), or nil. Parts are walked in
      # order: the walk ends without a token at the first part that is a file (it has a `filename`), at a part that
      # does not end within *preamble*, and at a field whose `name` is given twice. So the token field has to come
      # before the files in the form, and a `_csrf` placed after an upload is not found.
      def self.multipart_field(preamble : Bytes, boundary : String, name : String) : String?
        text = String.new(preamble)
        delimiter = "--#{boundary}"
        position = text.index(delimiter) || return
        loop do
          position += delimiter.size
          return if text[position, 2]? == "--"
          headers_start = text.index('\n', position) || return
          headers_start += 1
          headers_end, value_start, break_size = part_head_end(text, headers_start) || return
          # An empty value has no break of its own: the one that ends the headers is the one before the delimiter.
          closing, consumed = part_end(text, value_start - break_size, delimiter) || return

          params = disposition_params(text[headers_start...headers_end])
          return if params.nil? || params.has_key?("filename") || params.has_key?("filename*")
          if params["name"]? == name
            return closing < value_start ? "" : text[value_start...closing]
          end
          position = closing + consumed - delimiter.size
        end
      end

      # The end of the header block, where the value starts, and the size of the line break that ends the last header.
      private def self.part_head_end(text : String, from : Int32) : {Int32, Int32, Int32}?
        crlf = text.index("\r\n\r\n", from)
        lf = text.index("\n\n", from)
        if crlf && (lf.nil? || crlf < lf)
          {crlf, crlf + 4, 2}
        elsif lf
          {lf, lf + 2, 1}
        end
      end

      # Where the part ends: the line break before the next delimiter (which belongs to the delimiter, not the value),
      # and how many bytes that break and the delimiter take.
      private def self.part_end(text : String, from : Int32, delimiter : String) : {Int32, Int32}?
        crlf = text.index("\r\n#{delimiter}", from)
        lf = text.index("\n#{delimiter}", from)
        if crlf && lf && lf == crlf + 1
          {crlf, 2 + delimiter.size}
        elsif lf
          {lf, 1 + delimiter.size}
        end
      end

      # The `name`, `filename` ... parameters of the part's Content-Disposition header, with quotes honoured;
      # nil when it has none, is not `form-data`, or repeats a parameter (two parsers could pick different ones).
      private def self.disposition_params(headers : String) : Hash(String, String)?
        line = headers.each_line.find(&.downcase.starts_with?("content-disposition:")) || return
        pieces = split_params(line.partition(':')[2])
        return unless pieces.shift?.try(&.strip.downcase) == "form-data"

        params = {} of String => String
        pieces.each do |piece|
          key, separator, value = piece.partition('=')
          next if separator.empty?
          key = key.strip.downcase
          return if params.has_key?(key)
          params[key] = value.strip.lchop('"').rchop('"')
        end
        params
      end

      private def self.split_params(text : String) : Array(String)
        pieces = [] of String
        start = 0
        quoted = false
        text.each_char_with_index do |char, index|
          quoted = !quoted if char == '"'
          next unless char == ';' && !quoted
          pieces << text[start...index]
          start = index + 1
        end
        pieces << text[start..]
        pieces
      end

      # Extract token from cookie
      private def extract_token_from_cookie(context : HTTP::Server::Context) : String?
        cookie_token(context)
      end

      protected def cookie_token(context : HTTP::Server::Context) : String?
        cookies = HTTP::Cookies.from_client_headers(context.request.headers)
        cookies[@cookie_name]?.try(&.value)
      end

      # The token cookie `set_token_cookie` put on this response: live, non-empty and for no narrower path than it
      # gives. A token kept elsewhere (a synchronizer token store that is not the cookie) is never read from the response.
      private def issued_token(context : HTTP::Server::Context) : String?
        return if @strategy.synchronizer_token? && !token_store.is_a?(CookieTokenStore)
        cookie = context.response.cookies[@cookie_name]?
        cookie.value if cookie && !cookie.expired? && !cookie.value.empty? && (cookie.path || "/") == "/"
      end

      # Set CSRF token cookie. `Path=/`: without a path the browser keeps it for the directory of the page that
      # issued it (RFC 6265 default-path), and a form posting outside that directory is refused.
      protected def set_token_cookie(context : HTTP::Server::Context, token : String)
        cookie = HTTP::Cookie.new(
          name: @cookie_name,
          value: token,
          path: "/",
          max_age: Time::Span.new(seconds: @cookie_max_age),
          secure: @secure_cookies && (context.request.headers["X-Forwarded-Proto"]? == "https"),
          http_only: true,
          samesite: @cookie_same_site
        )

        context.response.cookies << cookie
      end

      # Create HMAC signature for token
      private def create_hmac_signature(data : String) : String
        digest = OpenSSL::HMAC.digest(:sha256, secret_key, data)
        Base64.urlsafe_encode(digest)
      end

      # Verify HMAC signature
      private def verify_hmac_token(token : String) : Bool
        parts = token.split(":")
        return false unless parts.size == 3

        base_token, timestamp, signature = parts

        # Check token age (optional, prevents replay attacks)
        begin
          token_time = Time.unix(timestamp.to_i64)
          return false if (Clock.now - token_time).total_seconds > @cookie_max_age
        rescue ex : ArgumentError | OverflowError
          return false
        end

        # Verify signature
        expected_signature = create_hmac_signature("#{base_token}:#{timestamp}")
        Crypto::Subtle.constant_time_compare(signature, expected_signature)
      end

      # Origin validation (additional security layer)
      def validate_origin(context : HTTP::Server::Context) : Bool
        origin = context.request.headers["Origin"]?
        referer = context.request.headers["Referer"]?

        # Get expected origin from request
        scheme = context.request.headers["X-Forwarded-Proto"]? || "http"
        expected_origin = "#{scheme}://#{context.request.headers["Host"]}"

        # Check Origin header first
        if origin
          return origin == expected_origin
        end

        # Fallback to Referer header
        if referer
          begin
            referer_uri = URI.parse(referer)
            referer_origin = "#{referer_uri.scheme}://#{referer_uri.host}"
            referer_origin += ":#{referer_uri.port}" if referer_uri.port != 80 && referer_uri.port != 443
            return referer_origin == expected_origin
          rescue ex : URI::Error
            return false
          end
        end

        # No origin information available
        false
      end
    end
  end
end

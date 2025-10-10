require "random/secure"
require "crypto/subtle"
require "openssl/hmac"
require "http"
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

      # Instance-level configuration properties
      property strategy : Strategy
      property secret_key : String
      property cookie_name : String
      property header_name : String
      property param_name : String
      property cookie_max_age : Int32
      property cookie_same_site : HTTP::Cookie::SameSite
      property secure_cookies : Bool

      # Default instance for backward compatibility
      @@default_instance : CSRF? = nil
      @@instance_mutex = Mutex.new

      # Exception for CSRF validation failures
      class InvalidTokenError < Exception
        def initialize(message = "Invalid CSRF token")
          super(message)
        end
      end

      def initialize(
        @skip_routes : Array(String) = [] of String,
        @strategy : Strategy = Strategy::SignedDoubleSubmit,
        @secret_key : String = Random::Secure.urlsafe_base64(HMAC_SECRET_LENGTH),
        @cookie_name : String = COOKIE_KEY,
        @header_name : String = HEADER_KEY,
        @param_name : String = PARAM_KEY,
        @cookie_max_age : Int32 = COOKIE_MAX_AGE,
        @cookie_same_site : HTTP::Cookie::SameSite = COOKIE_SAME_SITE,
        @secure_cookies : Bool = true,
      )
      end

      # Get default instance (backward compatibility)
      def self.default : CSRF
        @@instance_mutex.synchronize do
          @@default_instance ||= new
        end
      end

      # Reset default instance (useful for testing)
      def self.reset_default!
        @@instance_mutex.synchronize do
          @@default_instance = nil
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

        # Skip CSRF protection for AJAX requests with custom headers (preflight protection)
        if ajax_request_with_custom_headers?(context)
          call_next(context)
          return
        end

        # Validate CSRF token
        if valid_token?(context)
          call_next(context)
        else
          Log.warn { "CSRF token validation failed for #{context.request.method} #{context.request.path}" }
          Log.debug { "Request headers: #{context.request.headers.inspect}" }

          context.response.status = HTTP::Status::FORBIDDEN
          context.response.print "CSRF token validation failed"
        end
      end

      # Check if HTTP method is safe (doesn't require CSRF protection)
      private def safe_method?(method : String) : Bool
        !UNSAFE_METHODS.includes?(method.upcase)
      end

      # Check if route should skip CSRF protection
      private def skip_route?(path : String) : Bool
        @skip_routes.any? { |route| path.starts_with?(route) }
      end

      # Check if request is AJAX with custom headers (provides CSRF protection)
      private def ajax_request_with_custom_headers?(context : HTTP::Server::Context) : Bool
        # Check for common AJAX headers that require preflight
        ajax_headers = ["X-Requested-With", "Content-Type"]
        content_type = context.request.headers["Content-Type"]?

        # JSON requests require preflight
        if content_type && content_type.starts_with?("application/json")
          return true
        end

        # Custom headers require preflight
        ajax_headers.any? { |header| context.request.headers.has_key?(header) }
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

      # Generate CSRF token for forms/AJAX requests
      def token(context : HTTP::Server::Context) : String
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
        token_value = token(context)
        %Q(<input type="hidden" name="#{@param_name}" value="#{token_value}" />)
      end

      # Generate meta tag with CSRF token for AJAX requests
      def metatag(context : HTTP::Server::Context) : String
        token_value = token(context)
        %Q(<meta name="#{@param_name}" content="#{token_value}" />)
      end

      # SYNCHRONIZER TOKEN PATTERN
      # Token stored in session/cookie, compared with submitted token

      private def validate_synchronizer_token(context : HTTP::Server::Context) : Bool
        request_token = extract_token_from_request(context)
        session_token = extract_token_from_cookie(context)

        return false unless request_token && session_token

        # Constant-time comparison to prevent timing attacks
        Crypto::Subtle.constant_time_compare(request_token, session_token)
      end

      private def generate_synchronizer_token(context : HTTP::Server::Context) : String
        # Generate or retrieve existing token from cookie
        if existing_token = extract_token_from_cookie(context)
          existing_token
        else
          new_token = Random::Secure.urlsafe_base64(TOKEN_LENGTH)
          set_token_cookie(context, new_token)
          new_token
        end
      end

      # SIGNED DOUBLE SUBMIT COOKIE PATTERN (RECOMMENDED)
      # Token is HMAC-signed with secret, cookie and form token must match

      private def validate_signed_double_submit(context : HTTP::Server::Context) : Bool
        request_token = extract_token_from_request(context)
        cookie_token = extract_token_from_cookie(context)

        return false unless request_token && cookie_token

        # Both tokens must be identical
        return false unless Crypto::Subtle.constant_time_compare(request_token, cookie_token)

        # Verify HMAC signature
        verify_hmac_token(request_token)
      end

      private def generate_signed_double_submit_token(context : HTTP::Server::Context) : String
        # Generate base token
        base_token = Random::Secure.urlsafe_base64(TOKEN_LENGTH)
        timestamp = Time.utc.to_unix.to_s

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
        request_token = extract_token_from_request(context)
        cookie_token = extract_token_from_cookie(context)

        return false unless request_token && cookie_token

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

      # Extract token from form data
      private def extract_token_from_form(context : HTTP::Server::Context) : String?
        content_type = context.request.headers["Content-Type"]?
        return nil unless content_type

        if content_type.starts_with?("application/x-www-form-urlencoded")
          if body = context.request.body.try(&.gets_to_end)
            params = HTTP::Params.parse(body)
            # Restore body for other handlers
            context.request.body = IO::Memory.new(body)
            return params[@param_name]?
          end
        elsif content_type.starts_with?("multipart/form-data")
          # Handle multipart form data
          # Note: This is a simplified implementation
          # In practice, you'd want to use a proper multipart parser
          if body = context.request.body.try(&.gets_to_end)
            # Look for CSRF token in multipart data
            if match = body.match(/name="#{@param_name}".*?\r?\n\r?\n([^\r\n]+)/)
              context.request.body = IO::Memory.new(body)
              return match[1]?
            end
          end
        end

        nil
      end

      # Extract token from cookie
      private def extract_token_from_cookie(context : HTTP::Server::Context) : String?
        cookies = HTTP::Cookies.from_client_headers(context.request.headers)
        cookies[@cookie_name]?.try(&.value)
      end

      # Set CSRF token cookie
      private def set_token_cookie(context : HTTP::Server::Context, token : String)
        cookie = HTTP::Cookie.new(
          name: @cookie_name,
          value: token,
          max_age: Time::Span.new(seconds: @cookie_max_age),
          secure: @secure_cookies && (context.request.headers["X-Forwarded-Proto"]? == "https"),
          http_only: true,
          samesite: @cookie_same_site
        )

        context.response.cookies << cookie
      end

      # Create HMAC signature for token
      private def create_hmac_signature(data : String) : String
        digest = OpenSSL::HMAC.digest(:sha256, @secret_key, data)
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
          return false if (Time.utc - token_time).total_seconds > @cookie_max_age
        rescue
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
          rescue
            return false
          end
        end

        # No origin information available
        false
      end
    end
  end
end

require "random/secure"
require "crypto/subtle"
require "http"

module Azu
  module Handler
    # The CSRF Handler adds support for Cross Site Request Forgery.
    class CSRF
      include HTTP::Handler

      CHECK_METHODS = %w(PUT POST PATCH DELETE)
      HEADER_KEY    = "X-CSRF-TOKEN"
      PARAM_KEY     = "_csrf"
      CSRF_KEY      = "csrf.token"
      TOKEN_LENGTH  = 32

      class_property token_strategy : PersistentToken | RefreshableToken = PersistentToken

      # Initialize with optional cookie provider, defaults to HTTP::Cookies
      def initialize(@cookie_provider : HTTP::Cookies = HTTP::Cookies.new)
      end

      def call(context : HTTP::Server::Context)
        if valid_http_method?(context) || self.class.token_strategy.valid_token?(context)
          call_next(context)
        else
          error_context = Azu::ErrorContext.from_http_context(context)
          raise Azu::Response::Forbidden.new(error_context)
        end
      end

      def valid_http_method?(context)
        !CHECK_METHODS.includes?(context.request.method)
      end

      # Generate token for a given cookies instance
      def self.token(cookies : HTTP::Cookies) : String
        token_strategy.token(cookies)
      end

      # Generate token from context (convenience method)
      def self.token(context) : String
        cookies = cookies_from_context(context)
        token(cookies)
      end

      # Generate HTML tag with token from cookies
      def self.tag(cookies : HTTP::Cookies) : String
        %Q(<input type="hidden" name="#{PARAM_KEY}" value="#{token(cookies)}" />)
      end

      # Generate HTML tag with token from context (convenience method)
      def self.tag(context) : String
        cookies = cookies_from_context(context)
        tag(cookies)
      end

      # Generate meta tag with token from cookies
      def self.metatag(cookies : HTTP::Cookies) : String
        %Q(<meta name="#{PARAM_KEY}" content="#{token(cookies)}" />)
      end

      # Generate meta tag with token from context (convenience method)
      def self.metatag(context) : String
        cookies = cookies_from_context(context)
        metatag(cookies)
      end

      # Helper method to get cookies from context
      def self.cookies_from_context(context) : HTTP::Cookies
        HTTP::Cookies.from_client_headers(context.request.headers)
      end

      # Validate token with cookies and request token
      def self.valid_token?(cookies : HTTP::Cookies, request_token : String?) : Bool
        token_strategy.valid_token?(cookies, request_token)
      end

      # Validate token with context (convenience method)
      def self.valid_token?(context) : Bool
        cookies = cookies_from_context(context)
        request_token = context.request.headers[HEADER_KEY]?
        valid_token?(cookies, request_token)
      end

      module BaseToken
        def request_token(context)
          # First try to get token from header
          if token = context.request.headers[HEADER_KEY]?
            return token
          end

          # Then try to get token from query parameters (for GET requests)
          if token = context.request.query_params[PARAM_KEY]?
            return token
          end

          # For POST/PUT/PATCH requests with form data, read the raw body
          if CHECK_METHODS.includes?(context.request.method) &&
             context.request.content_type.try(&.to_s.starts_with?("application/x-www-form-urlencoded"))
            # Read the raw body to extract CSRF token
            if body = context.request.body.try(&.gets_to_end)
              params = HTTP::Params.parse(body)
              if token = params[PARAM_KEY]?
                # Restore the body so the endpoint can read it
                context.request.body = IO::Memory.new(body)
                return token
              end
            end
          end

          nil
        end

        def real_session_token(cookies : HTTP::Cookies) : String
          if cookies[CSRF_KEY]?
            cookies[CSRF_KEY].value
          else
            Random::Secure.urlsafe_base64(TOKEN_LENGTH)
          end
        end

        def real_session_token(context) : String
          cookies = CSRF.cookies_from_context(context)
          token = real_session_token(cookies)
          # Set the cookie in the response if it doesn't exist
          unless cookies[CSRF_KEY]?
            context.response.cookies << HTTP::Cookie.new(CSRF_KEY, token, http_only: true, secure: context.request.secure?)
          end
          token
        end
      end

      module RefreshableToken
        extend self
        extend BaseToken

        def token(cookies : HTTP::Cookies) : String
          real_session_token(cookies)
        end

        def token(context) : String
          real_session_token(context)
        end

        def valid_token?(cookies : HTTP::Cookies, request_token : String?) : Bool
          if request_token && cookies[CSRF_KEY]?
            request_token == cookies[CSRF_KEY].value
          else
            false
          end
        end

        def valid_token?(context) : Bool
          cookies = CSRF.cookies_from_context(context)
          request_token = request_token(context)
          if valid_token?(cookies, request_token) && cookies[CSRF_KEY]?
            # Delete the cookie from response
            context.response.cookies.delete(CSRF_KEY)
            true
          else
            false
          end
        end
      end

      module PersistentToken
        extend self
        extend BaseToken

        def valid_token?(cookies : HTTP::Cookies, request_token : String?) : Bool
          if request_token && real_session_token(cookies)
            decoded_request = Base64.decode(request_token.to_s)
            return false unless decoded_request.size == TOKEN_LENGTH * 2

            unmasked = TokenOperations.unmask(decoded_request)
            session_token = Base64.decode(real_session_token(cookies))
            return Crypto::Subtle.constant_time_compare(unmasked, session_token)
          end
          false
        rescue Base64::Error
          false
        end

        def valid_token?(context) : Bool
          cookies = CSRF.cookies_from_context(context)
          request_token = request_token(context)
          valid_token?(cookies, request_token)
        end

        def token(cookies : HTTP::Cookies) : String
          unmask_token = Base64.decode(real_session_token(cookies))
          TokenOperations.mask(unmask_token)
        end

        def token(context) : String
          cookies = CSRF.cookies_from_context(context)
          token(cookies)
        end

        module TokenOperations
          extend self

          # Creates a masked version of the authenticity token that varies
          # on each request. The masking is used to mitigate SSL attacks
          # like BREACH.
          def mask(unmasked_token : Bytes) : String
            one_time_pad = Bytes.new(TOKEN_LENGTH).tap { |buf| Random::Secure.random_bytes(buf) }
            encrypted_csrf_token = xor_bytes_arrays(unmasked_token, one_time_pad)

            masked_token = IO::Memory.new
            masked_token.write(one_time_pad)
            masked_token.write(encrypted_csrf_token)
            Base64.urlsafe_encode(masked_token.to_slice)
          end

          def unmask(masked_token : Bytes) : Bytes
            one_time_pad = masked_token[0, TOKEN_LENGTH]
            encrypted_csrf_token = masked_token[TOKEN_LENGTH, TOKEN_LENGTH]
            xor_bytes_arrays(encrypted_csrf_token, one_time_pad)
          end

          def xor_bytes_arrays(token : Bytes, pad : Bytes) : Bytes
            token.map_with_index { |b, i| b ^ pad[i] }
          end
        end
      end
    end
  end
end

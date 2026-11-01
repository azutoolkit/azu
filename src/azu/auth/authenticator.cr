require "base64"
require "crypto/subtle"
require "digest/sha256"
require "http/server"
require "json"
require "openssl/hmac"
require "./principal"
require "./access"
require "../response"

module Azu
  module Auth
    # Raised when a token verification or introspection store is temporarily unreachable.
    # `Azu::Handler::Authentication` answers `503 Service Unavailable` with `Retry-After: 1`
    # instead of `401 Unauthorized` so clients do not discard valid credentials.
    class VerificationUnavailable < Exception
    end

    # Base interface for request authenticators.
    #
    # Contract:
    # - Returns `Principal` when credentials are present and valid.
    # - Returns `nil` when no credentials for this authenticator's scheme are present on the request.
    # - Raises `Azu::Response::AuthenticationError` (with specific `code` and `detail`) when presented
    #   credentials are malformed, invalid, expired, or revoked.
    # - Raises `Azu::Auth::VerificationUnavailable` (or `Authly::VerificationUnavailable`) when
    #   verification cannot be carried out due to an upstream store outage (`503`).
    abstract class Authenticator
      MAX_TOKEN_BYTES = 8192

      abstract def authenticate(context : HTTP::Server::Context) : Principal?

      # Extracts a bearer token from the `Authorization: Bearer <token>` header,
      # returning `nil` when no Bearer header is present.
      protected def extract_bearer_token(context : HTTP::Server::Context) : String?
        header = context.request.headers["Authorization"]?
        return nil unless header

        stripped = header.strip
        return nil unless stripped.size >= 6 && stripped[0, 6].compare("Bearer", case_insensitive: true) == 0
        return nil if stripped.size > 6 && !stripped[6].ascii_whitespace?

        token = stripped[6..].strip
        token.empty? ? nil : token
      end
    end

    # Wraps a `Proc(HTTP::Server::Context, Principal?)` as an `Authenticator`.
    class ProcAuthenticator < Authenticator
      def initialize(@proc : HTTP::Server::Context -> Principal?)
      end

      def self.new(&block : HTTP::Server::Context -> Principal?) : self
        new(block)
      end

      def authenticate(context : HTTP::Server::Context) : Principal?
        @proc.call(context)
      end
    end

    # Tries multiple authenticators in sequence, returning the first non-nil `Principal`.
    # Any `Response::AuthenticationError` raised by an authenticator for invalid presented credentials
    # propagates immediately.
    class ChainAuthenticator < Authenticator
      getter authenticators : Array(Authenticator)

      def initialize(@authenticators : Array(Authenticator))
      end

      def initialize(*authenticators : Authenticator)
        @authenticators = authenticators.to_a
      end

      def authenticate(context : HTTP::Server::Context) : Principal?
        @authenticators.each do |auth|
          if principal = auth.authenticate(context)
            return principal
          end
        end
        nil
      end
    end

    # Built-in `Authorization: Bearer <token>` authenticator.
    #
    # Supports:
    # 1. Static tokens hashed with SHA-256 and compared in constant time (`Crypto::Subtle.constant_time_compare`),
    #    so raw static secrets are not retained in memory or leaked via timing side-channels.
    # 2. A custom lookup proc `(String, HTTP::Server::Context) -> Principal?` (e.g. database, Redis, or token introspection).
    class BearerAuthenticator < Authenticator
      private record HashedToken, digest : Bytes, principal : Principal

      @hashed_tokens : Array(HashedToken) = [] of HashedToken
      @lookup : Proc(String, HTTP::Server::Context, Principal?)?
      property invalid_code : String
      property invalid_message : String
      property www_authenticate : String

      def initialize(
        tokens = {} of String => Principal,
        *,
        @lookup : Proc(String, HTTP::Server::Context, Principal?)? = nil,
        @invalid_code : String = "invalid_token",
        @invalid_message : String = "Invalid or expired bearer token",
        @www_authenticate : String = "Bearer",
      )
        tokens.each do |raw_token, principal|
          add_token(raw_token, principal)
        end
      end

      def self.new(
        tokens = {} of String => Principal,
        *,
        invalid_code : String = "invalid_token",
        invalid_message : String = "Invalid or expired bearer token",
        www_authenticate : String = "Bearer",
        &block : String, HTTP::Server::Context -> Principal?
      ) : self
        new(
          tokens,
          lookup: block,
          invalid_code: invalid_code,
          invalid_message: invalid_message,
          www_authenticate: www_authenticate
        )
      end

      # Registers a static bearer token hashed with SHA-256.
      def add_token(raw_token : String, principal : Principal) : self
        digest = Digest::SHA256.digest(raw_token)
        @hashed_tokens << HashedToken.new(digest, principal)
        self
      end

      def authenticate(context : HTTP::Server::Context) : Principal?
        token = extract_bearer_token(context)
        return nil unless token
        return nil if token.bytesize > MAX_TOKEN_BYTES

        if principal = match_static_token(token)
          return principal
        end

        if lookup = @lookup
          if principal = lookup.call(token, context)
            return principal
          end
        end

        nil
      end

      private def match_static_token(token : String) : Principal?
        return nil if @hashed_tokens.empty?

        candidate = Digest::SHA256.digest(token)
        matched : Principal? = nil
        @hashed_tokens.each do |entry|
          if Crypto::Subtle.constant_time_compare(entry.digest, candidate)
            matched = entry.principal
          end
        end
        matched
      end
    end

    # Built-in HMAC (`HS256`, `HS384`, `HS512`) JSON Web Token (`JWT`) authenticator using Crystal's
    # standard library (`OpenSSL::HMAC`, `Base64`, `JSON`, `Crypto::Subtle`).
    #
    # Verifies:
    # - Signature and exact `alg` header match (never trusting `"none"` or mismatched algorithms)
    # - `exp` and `nbf` claims (with configurable `leeway`)
    # - `iss` (when `issuer` is set) and `aud` (when `audience` is set)
    # - Builds `Azu::Auth::Identity` via `Identity.from_claims` and runs optional `validator`
    class JWTAuthenticator < Authenticator
      getter issuer : String?
      getter audience : String?
      getter algorithm : String
      getter leeway : Int64
      property invalid_code : String
      property invalid_message : String
      property expired_code : String
      property expired_message : String
      property www_authenticate : String
      @secret : String
      @validator : Proc(Identity, HTTP::Server::Context, Bool)?

      def initialize(
        @secret : String,
        *,
        @issuer : String? = nil,
        @audience : String? = nil,
        algorithm : String | Symbol = "HS256",
        leeway : Int32 | Int64 | Time::Span = 0,
        @validator : Proc(Identity, HTTP::Server::Context, Bool)? = nil,
        @invalid_code : String = "invalid_token",
        @invalid_message : String = "Invalid or malformed token",
        @expired_code : String = "token_expired",
        @expired_message : String = "Token has expired",
        @www_authenticate : String = "Bearer error=\"invalid_token\"",
      )
        raise ArgumentError.new("JWT secret must not be empty") if @secret.empty?
        @algorithm = algorithm.to_s.upcase
        unless @algorithm.in?("HS256", "HS384", "HS512")
          raise ArgumentError.new("Unsupported HMAC algorithm #{@algorithm.inspect}; use HS256, HS384, or HS512 (or c.auth.authly for RS256/ES256/EdDSA)")
        end
        @leeway = leeway.is_a?(Time::Span) ? leeway.total_seconds.to_i64 : leeway.to_i64
      end

      def self.new(
        secret : String,
        *,
        issuer : String? = nil,
        audience : String? = nil,
        algorithm : String | Symbol = "HS256",
        leeway : Int32 | Int64 | Time::Span = 0,
        invalid_code : String = "invalid_token",
        invalid_message : String = "Invalid or malformed token",
        expired_code : String = "token_expired",
        expired_message : String = "Token has expired",
        www_authenticate : String = "Bearer error=\"invalid_token\"",
        &validator : Identity, HTTP::Server::Context -> Bool
      ) : self
        new(
          secret,
          issuer: issuer,
          audience: audience,
          algorithm: algorithm,
          leeway: leeway,
          validator: validator,
          invalid_code: invalid_code,
          invalid_message: invalid_message,
          expired_code: expired_code,
          expired_message: expired_message,
          www_authenticate: www_authenticate
        )
      end

      def authenticate(context : HTTP::Server::Context) : Principal?
        token = extract_bearer_token(context)
        return nil unless token
        reject!(@invalid_message, @invalid_code) if token.bytesize > MAX_TOKEN_BYTES

        parts = token.split('.', 4)
        reject!(@invalid_message, @invalid_code) unless parts.size == 3

        header_b64, payload_b64, sig_b64 = parts[0], parts[1], parts[2]
        header = decode_json_object(header_b64)
        reject!(@invalid_message, @invalid_code) unless header["alg"]?.try(&.as_s?) == @algorithm

        verify_signature!("#{header_b64}.#{payload_b64}", sig_b64)

        payload = decode_json_object(payload_b64)
        verify_claims!(payload)

        identity = Identity.from_claims(payload, auth_scheme: :jwt)
        if (check = @validator) && !check.call(identity, context)
          reject!("Token is revoked or no longer valid", @invalid_code)
        end
        identity
      end

      private def verify_signature!(signing_input : String, sig_b64 : String) : Nil
        actual_sig = begin
          Base64.decode(sig_b64)
        rescue Base64::Error
          reject!(@invalid_message, @invalid_code)
        end

        digest_alg = case @algorithm
                     when "HS384" then OpenSSL::Algorithm::SHA384
                     when "HS512" then OpenSSL::Algorithm::SHA512
                     else              OpenSSL::Algorithm::SHA256
                     end
        expected_sig = OpenSSL::HMAC.digest(digest_alg, @secret, signing_input)
        unless Crypto::Subtle.constant_time_compare(expected_sig, actual_sig)
          reject!(@invalid_message, @invalid_code)
        end
      end

      private def decode_json_object(segment : String) : Hash(String, JSON::Any)
        raw = Base64.decode_string(segment)
        parsed = JSON.parse(raw)
        parsed.as_h? || reject!(@invalid_message, @invalid_code)
      rescue Base64::Error | JSON::ParseException
        reject!(@invalid_message, @invalid_code)
      end

      private def verify_claims!(payload : Hash(String, JSON::Any)) : Nil
        verify_time_claims!(payload)

        if expected_iss = @issuer
          reject!(@invalid_message, @invalid_code) unless payload["iss"]?.try(&.as_s?) == expected_iss
        end

        if expected_aud = @audience
          reject!(@invalid_message, @invalid_code) unless audience_matches?(payload["aud"]?, expected_aud)
        end
      end

      private def verify_time_claims!(payload : Hash(String, JSON::Any)) : Nil
        now = Time.utc.to_unix

        if exp_val = payload["exp"]?
          exp = exp_val.as_i64? || exp_val.as_f?.try(&.to_i64)
          reject!(@invalid_message, @invalid_code) unless exp
          reject!(@expired_message, @expired_code) if now > exp + @leeway
        end

        if nbf_val = payload["nbf"]?
          nbf = nbf_val.as_i64? || nbf_val.as_f?.try(&.to_i64)
          reject!(@invalid_message, @invalid_code) unless nbf
          reject!(@invalid_message, @invalid_code) if now + @leeway < nbf
        end
      end

      private def audience_matches?(aud_val : JSON::Any?, expected_aud : String) : Bool
        case raw_aud = aud_val.try(&.raw)
        when String then raw_aud == expected_aud
        when Array  then raw_aud.any? { |item| item.as_s? == expected_aud }
        else             false
        end
      end

      private def reject!(message : String, code : String) : NoReturn
        raise Response::AuthenticationError.new(
          message,
          code: code,
          www_authenticate: @www_authenticate
        )
      end
    end

    # First-class adapter for `azutoolkit/authly` (`Authly::TokenVerifier` / `Authly::StrategyTokenVerifier`)
    # or any verifier object responding to `#verify(token : String)`.
    #
    # - Converts verified `Authly::Claims` (or claim hashes) into `Azu::Auth::Identity` (`sub` -> `id`,
    #   space-delimited `scope` -> `permissions`/`scopes`, `roles`/`role` -> `roles`, full `payload` -> `claims`).
    # - Populates `context.authly_claims` when `Authly` is loaded so downstream Authly helpers continue to work.
    # - Translates `Authly::VerificationUnavailable` (or `Azu::Auth::VerificationUnavailable`) into a `503`
    #   with `Retry-After: 1` via `Azu::Handler::Authentication`.
    class AuthlyAuthenticator(V) < Authenticator
      getter verifier : V
      getter realm : String
      property invalid_code : String
      property invalid_message : String
      @validator : Proc(Identity, HTTP::Server::Context, Bool)?

      def initialize(
        @verifier : V,
        *,
        @realm : String = "authly",
        @validator : Proc(Identity, HTTP::Server::Context, Bool)? = nil,
        @invalid_code : String = "invalid_token",
        @invalid_message : String = "Invalid or expired access token",
      )
      end

      def self.new(
        verifier : V,
        *,
        realm : String = "authly",
        invalid_code : String = "invalid_token",
        invalid_message : String = "Invalid or expired access token",
        &validator : Identity, HTTP::Server::Context -> Bool
      ) : self
        new(
          verifier,
          realm: realm,
          validator: validator,
          invalid_code: invalid_code,
          invalid_message: invalid_message
        )
      end

      def authenticate(context : HTTP::Server::Context) : Principal?
        token = extract_bearer_token(context)
        return nil unless token
        reject! if token.bytesize > MAX_TOKEN_BYTES

        verified = begin
          @verifier.verify(token)
        rescue ex : VerificationUnavailable
          raise ex
        rescue ex
          if ex.class.name == "Authly::VerificationUnavailable"
            raise VerificationUnavailable.new(ex.message || "Token store unavailable", ex)
          end
          raise ex
        end

        reject! unless verified

        {% if @top_level.has_constant?("Authly") %}
          if verified.is_a?(Authly::Claims)
            context.authly_claims = verified
          end
        {% end %}

        identity = to_identity(verified)
        if (check = @validator) && !check.call(identity, context)
          reject!("Token is revoked or no longer valid")
        end
        identity
      end

      private def to_identity(verified) : Identity
        if verified.is_a?(Identity)
          verified
        elsif verified.responds_to?(:payload)
          Identity.from_claims(verified.payload, auth_scheme: :bearer)
        elsif verified.is_a?(Hash(String, JSON::Any))
          Identity.from_claims(verified, auth_scheme: :bearer)
        else
          raise ArgumentError.new("Unsupported verifier return type #{verified.class}")
        end
      end

      private def reject!(message : String = @invalid_message) : NoReturn
        raise Response::AuthenticationError.new(
          message,
          code: @invalid_code,
          www_authenticate: "Bearer realm=\"#{@realm}\", error=\"invalid_token\""
        )
      end
    end

    class Configuration
      # Configures HMAC JWT authentication by convention, automatically enabling `c.auth`
      # and setting `c.auth.bearer_format ||= "JWT"`.
      def jwt(
        secret : String = Env.secret("JWT_SECRET"),
        *,
        issuer : String? = Env.fetch?("JWT_ISSUER"),
        audience : String? = Env.fetch?("JWT_AUDIENCE"),
        algorithm : String | Symbol = "HS256",
        leeway : Int32 | Int64 | Time::Span = 0,
      ) : JWTAuthenticator
        @bearer_format ||= "JWT"
        auth = JWTAuthenticator.new(
          secret: secret,
          issuer: issuer,
          audience: audience,
          algorithm: algorithm,
          leeway: leeway
        )
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures HMAC JWT authentication with a per-request revocation / account-state validator block.
      def jwt(
        secret : String = Env.secret("JWT_SECRET"),
        *,
        issuer : String? = Env.fetch?("JWT_ISSUER"),
        audience : String? = Env.fetch?("JWT_AUDIENCE"),
        algorithm : String | Symbol = "HS256",
        leeway : Int32 | Int64 | Time::Span = 0,
        &validator : Identity, HTTP::Server::Context -> Bool
      ) : JWTAuthenticator
        @bearer_format ||= "JWT"
        auth = JWTAuthenticator.new(
          secret: secret,
          issuer: issuer,
          audience: audience,
          algorithm: algorithm,
          leeway: leeway,
          &validator
        )
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures static Bearer token authentication by convention and enables `c.auth`.
      def bearer(tokens = {} of String => Principal) : BearerAuthenticator
        auth = BearerAuthenticator.new(tokens)
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures Bearer token authentication with a custom lookup block and enables `c.auth`.
      def bearer(
        tokens = {} of String => Principal,
        &lookup : String, HTTP::Server::Context -> Principal?
      ) : BearerAuthenticator
        auth = BearerAuthenticator.new(tokens, &lookup)
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures custom request authentication from a block and enables `c.auth`.
      def authenticate(&block : HTTP::Server::Context -> Principal?) : ProcAuthenticator
        auth = ProcAuthenticator.new(block)
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures Authly (`azutoolkit/authly`) or custom `TokenVerifier` authentication by convention,
      # enabling `c.auth` and optionally mounting Authly's OAuth 2.0 / OIDC provider endpoints (`provider: true`).
      def authly(
        verifier,
        *,
        realm : String = "authly",
        provider : Bool = false,
      )
        @bearer_format ||= "JWT"
        @oauth_provider = true if provider
        auth = AuthlyAuthenticator.new(verifier, realm: realm)
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Configures Authly (`azutoolkit/authly`) authentication with an additional per-request validator block.
      def authly(
        verifier,
        *,
        realm : String = "authly",
        provider : Bool = false,
        &validator : Identity, HTTP::Server::Context -> Bool
      )
        @bearer_format ||= "JWT"
        @oauth_provider = true if provider
        auth = AuthlyAuthenticator.new(verifier, realm: realm, &validator)
        self.authenticator = auth
        enable_by_convention!
        auth
      end

      # Zero-argument Authly setup when `Authly` (`azutoolkit/authly`) is loaded in the application:
      # builds `Authly::StrategyTokenVerifier.new(audience: audience, legacy_tokens: legacy_tokens)` automatically.
      def authly(
        *,
        audience : String? = Env.fetch?("JWT_AUDIENCE"),
        legacy_tokens : Bool = false,
        realm : String = "authly",
        provider : Bool = false,
      )
        {% if @top_level.has_constant?("Authly") %}
          verifier = Authly::StrategyTokenVerifier.new(audience: audience, legacy_tokens: legacy_tokens)
          authly(verifier, realm: realm, provider: provider)
        {% else %}
          raise ArgumentError.new("c.auth.authly without a verifier requires `require \"authly\"` (azutoolkit/authly), or pass a verifier responding to `#verify(token : String)`")
        {% end %}
      end
    end
  end
end

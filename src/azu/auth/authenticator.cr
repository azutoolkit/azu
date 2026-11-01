require "digest/sha256"
require "crypto/subtle"
require "http/server"
require "./principal"
require "./access"

module Azu
  module Auth
    # Base interface for request authenticators.
    #
    # Contract:
    # - Returns `Principal` when credentials are present and valid.
    # - Returns `nil` when no credentials for this authenticator's scheme are present on the request.
    # - Raises `Azu::Response::AuthenticationError` (with specific `code` and `detail`) when presented
    #   credentials are malformed, invalid, expired, or revoked.
    abstract class Authenticator
      abstract def authenticate(context : HTTP::Server::Context) : Principal?
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
    # 2. A custom lookup proc `(String, HTTP::Server::Context) -> Principal?` (e.g. database, Redis, or Authly introspection).
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
        header = context.request.headers["Authorization"]?
        return nil unless header

        stripped = header.strip
        return nil unless stripped.size >= 6 && stripped[0, 6].compare("Bearer", case_insensitive: true) == 0
        return nil if stripped.size > 6 && !stripped[6].ascii_whitespace?

        token = stripped[6..].strip
        return nil if token.empty?

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
  end
end

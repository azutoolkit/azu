require "base64"
require "crypto/subtle"
require "json"
require "openssl/hmac"
require "./errors"

module Azu
  module Spark
    # HMAC-SHA256 signed, expiring tokens: `base64url(payload) "." base64url(signature)`.
    #
    # Join tokens (kind `join`) travel in the rendered page and authorise a WebSocket to mount
    # one view with fixed props and session claims. Snapshot tokens (kind `snapshot`) carry the
    # persisted state of a view so it can survive a reconnect. The payload is signed, not
    # encrypted: never put secrets in it.
    module Token
      MAX_SIZE = 16 * 1024

      def self.sign(kind : String, claims : JSON::Any, ttl : Time::Span, secret : String = Spark.config.secret) : String
        payload = Base64.urlsafe_encode({kind: kind, exp: (Clock.now + ttl).to_unix, claims: claims}.to_json, padding: false)
        "#{payload}.#{signature(payload, secret)}"
      end

      # Returns the claims of a valid *kind* token, raising `InvalidToken` otherwise.
      def self.verify(kind : String, token : String, secret : String = Spark.config.secret) : JSON::Any
        raise InvalidToken.new("token too large") if token.bytesize > MAX_SIZE
        payload, separator, given = token.rpartition('.')
        raise InvalidToken.new("malformed token") if separator.empty?
        raise InvalidToken.new("bad signature") unless Crypto::Subtle.constant_time_compare(signature(payload, secret), given)

        envelope = decode(payload)
        raise InvalidToken.new("wrong token kind") unless envelope["kind"]?.try(&.as_s?) == kind
        raise InvalidToken.new("token expired") unless (expiry = envelope["exp"]?.try(&.as_i64?)) && expiry >= Clock.now.to_unix
        envelope["claims"]? || raise InvalidToken.new("token without claims")
      end

      private def self.signature(payload : String, secret : String) : String
        Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, secret, payload), padding: false)
      end

      private def self.decode(payload : String) : JSON::Any
        JSON.parse(Base64.decode_string(payload))
      rescue ex : Base64::Error | JSON::ParseException
        raise InvalidToken.new("malformed token payload")
      end
    end
  end
end

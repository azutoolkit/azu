require "digest/sha256"
require "json"
require "./errors"
require "./token"

module Azu
  module Spark
    # The persisted state of a page's components as a signed, expiring token the browser keeps and
    # sends back with `join` after a reconnect (see `Rehydrator`).
    #
    # Beyond the signature the token is bound to what it was issued for: the root component id
    # (unique per rendered page), a digest of that page's session claims, and, per component, the
    # class name, so it can be mounted by nobody else and into nothing else. It is versioned: a
    # format change invalidates old tokens, which merely costs a client its state.
    module Snapshot
      VERSION = 1

      # The persisted state of one component.
      struct Member
        include JSON::Serializable

        @[JSON::Field(key: "c")]
        getter type : String
        @[JSON::Field(key: "s")]
        getter state : JSON::Any

        def initialize(@type : String, @state : JSON::Any)
        end
      end

      # Signs *members* (component id => state) for the page *root_id*. Returns nil when the token
      # would exceed *max_size* bytes.
      def self.sign(root_id : String, session : Hash(String, String), members : Hash(String, Member),
                    ttl : Time::Span, secret : String, max_size : Int32) : String?
        claims = JSON.parse({v: VERSION, root: root_id, sid: digest(session), components: members}.to_json)
        token = Token.sign("snapshot", claims, ttl, secret)
        token unless token.bytesize > max_size
      end

      # The members of a valid *token* issued for *root_id* and *session*; raises `InvalidSnapshot` otherwise.
      def self.open(token : String, root_id : String, session : Hash(String, String), secret : String, max_size : Int32) : Hash(String, Member)
        raise InvalidSnapshot.new("snapshot too large") if token.bytesize > max_size
        claims = Token.verify("snapshot", token, secret)
        raise InvalidSnapshot.new("unsupported snapshot version") unless claims["v"]?.try(&.as_i?) == VERSION
        raise InvalidSnapshot.new("snapshot belongs to another page") unless claims["root"]?.try(&.as_s?) == root_id
        raise InvalidSnapshot.new("snapshot belongs to another session") unless claims["sid"]?.try(&.as_s?) == digest(session)
        Hash(String, Member).from_json(claims["components"].to_json)
      rescue ex : InvalidToken
        raise InvalidSnapshot.new(ex.message)
      rescue JSON::ParseException | JSON::SerializableError | KeyError
        raise InvalidSnapshot.new("malformed snapshot")
      end

      # Stable fingerprint of the session claims of a page.
      def self.digest(session : Hash(String, String)) : String
        Digest::SHA256.hexdigest(session.to_a.sort_by(&.first).to_json)
      end
    end
  end
end

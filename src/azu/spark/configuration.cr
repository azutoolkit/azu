require "random/secure"
require "./errors"

module Azu
  module Spark
    # Settings of the Spark live view layer, reachable as `Azu::CONFIG.spark`.
    #
    # ```
    # Azu::Spark.configure do |c|
    #   c.secret = ENV["SPARK_SECRET"]
    #   c.allowed_origins = ["https://app.example.com"]
    # end
    # ```
    class Configuration
      # URL the WebSocket is served from
      property path : String = ENV.fetch("SPARK_PATH", "/spark")

      # URL the client script is served from
      property assets_path : String = ENV.fetch("SPARK_ASSETS_PATH", "/_spark/azu_spark.js")

      # How long a rendered page may wait before joining
      property token_ttl : Time::Span = ENV.fetch("SPARK_TOKEN_TTL", "86400").to_i.seconds

      # Origins accepted besides the page's own origin, "*" accepts any
      property allowed_origins : Array(String) = ENV.fetch("SPARK_ALLOWED_ORIGINS", "").split(',').map(&.strip).reject(&.empty?)

      # Largest accepted client frame in bytes
      property max_message_size : Int32 = ENV.fetch("SPARK_MAX_MESSAGE_SIZE", "65536").to_i

      # Components (roots and children) a single connection may own
      property max_components : Int32 = ENV.fetch("SPARK_MAX_COMPONENTS", "200").to_i

      # Sustained events per second a connection may send, and the burst it may spend at once
      property events_per_second : Float64 = ENV.fetch("SPARK_EVENTS_PER_SECOND", "30").to_f
      property event_burst : Int32 = ENV.fetch("SPARK_EVENT_BURST", "60").to_i

      # Seconds between client heartbeats; a connection silent for `idle_timeout` is closed
      property heartbeat_interval : Time::Span = ENV.fetch("SPARK_HEARTBEAT_INTERVAL", "20").to_i.seconds
      property idle_timeout : Time::Span = ENV.fetch("SPARK_IDLE_TIMEOUT", "60").to_i.seconds

      # Largest signed state snapshot (bytes) handed to the client for reconnects
      property max_snapshot_size : Int32 = ENV.fetch("SPARK_MAX_SNAPSHOT_SIZE", "4096").to_i

      @secret : String? = ENV["SPARK_SECRET"]?.try { |value| value.empty? ? nil : value }
      @generated_secret : String? = nil
      @secret_mutex = Mutex.new

      setter secret : String?

      # Key used to sign join tokens and state snapshots.
      #
      # Production and staging refuse to run without an explicitly configured secret. Other
      # environments get a random per process secret (tokens do not survive a restart there).
      def secret : String
        if configured = @secret
          return configured
        end
        raise ConfigurationError.new("Azu::Spark needs a signing secret: set SPARK_SECRET or Azu::Spark.configure { |c| c.secret = ... }") if secret_required?

        @secret_mutex.synchronize { @generated_secret ||= Random::Secure.hex(32) }
      end

      private def secret_required? : Bool
        Azu.current_config.env.in?(Environment::Production, Environment::Staging)
      end
    end
  end
end

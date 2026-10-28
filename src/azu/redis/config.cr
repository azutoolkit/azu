require "uri"
require "openssl"
require "./retry"

module Azu
  module Redis
    # Everything that decides how a connection to Redis is made and used, in one value. Two clients whose
    # `pool_key` is equal share one pool (see `Azu::Redis.acquire`).
    #
    # `command_timeout` bounds every read and write on a connection (the `redis` shard has one setting for both).
    # `rediss://` URLs use TLS; `tls_ca_file` and `tls_verify` tune it and are ignored for `redis://`. Neither `inspect` nor `to_s` show the URL's
    # password.
    struct Config
      # The URLs whose unverified TLS was warned about (`ssl_context`), one line each.
      WARNED_UNVERIFIED = Set(String).new
      private WARNED_MUTEX      = Mutex.new
      DEFAULT_URL       = "redis://localhost:6379/0"

      # Where settings are read from: the process environment, or a hash in a spec.
      alias Source = Hash(String, String) | ENV.class

      alias PoolKey = Tuple(String, Int32, Time::Span, Time::Span, Time::Span, Time::Span, String?, Bool)

      getter url : String
      getter pool_size : Int32
      getter checkout_timeout : Time::Span
      getter connect_timeout : Time::Span
      getter command_timeout : Time::Span
      getter health_check_after : Time::Span
      getter retry : Retry
      getter tls_ca_file : String?
      getter? tls_verify : Bool
      getter name : String
      getter prefix : String

      def initialize(@url : String = DEFAULT_URL, @pool_size : Int32 = 5, @checkout_timeout : Time::Span = 5.seconds,
                     @connect_timeout : Time::Span = 5.seconds, @command_timeout : Time::Span = 5.seconds,
                     @health_check_after : Time::Span = 30.seconds, @retry : Retry = Retry.new,
                     @tls_ca_file : String? = nil, @tls_verify : Bool = true, @name : String = "azu", @prefix : String = "")
        raise ArgumentError.new("pool_size must be positive") unless @pool_size > 0
        raise ArgumentError.new("name must not contain whitespace") if @name.matches?(/\s/)
      end

      # Reads `REDIS_URL` (default `redis://localhost:6379/0`), `REDIS_POOL_SIZE`, `REDIS_POOL_TIMEOUT`,
      # `REDIS_CONNECT_TIMEOUT` and `REDIS_TIMEOUT` (seconds, fractions allowed), `REDIS_RETRIES`,
      # `REDIS_TLS_CA_FILE`, `REDIS_TLS_VERIFY` and `REDIS_PREFIX`. *url_names* are variables tried before `REDIS_URL`. A malformed number raises an `ArgumentError`
      # that names the variable and never shows its value.
      #
      # This is the one place the Redis variables are read; `url_from_env` serves the per-subsystem URLs.
      def self.from_env(env : Source = ::ENV, url_names : Array(String) = [] of String) : Config
        new(
          url: first_url(url_names, env),
          pool_size: env_int(env, "REDIS_POOL_SIZE", 5),
          checkout_timeout: env_seconds(env, "REDIS_POOL_TIMEOUT", 5.seconds),
          connect_timeout: env_seconds(env, "REDIS_CONNECT_TIMEOUT", 5.seconds),
          command_timeout: env_seconds(env, "REDIS_TIMEOUT", 5.seconds),
          retry: Retry.new(retries: env_int(env, "REDIS_RETRIES", 1)),
          tls_ca_file: env["REDIS_TLS_CA_FILE"]?.presence,
          tls_verify: !{"0", "false", "no", "off"}.includes?(env["REDIS_TLS_VERIFY"]?.try(&.downcase)),
          prefix: env["REDIS_PREFIX"]? || "")
      end

      # The first of *names* that is set, then `REDIS_URL`, then the default URL.
      def self.url_from_env(*names : String, env : Source = ::ENV) : String
        first_url(names.to_a, env)
      end

      def copy_with(url : String = @url, pool_size : Int32 = @pool_size, checkout_timeout : Time::Span = @checkout_timeout,
                    connect_timeout : Time::Span = @connect_timeout, command_timeout : Time::Span = @command_timeout,
                    health_check_after : Time::Span = @health_check_after, retry : Retry = @retry,
                    tls_ca_file : String? = @tls_ca_file, tls_verify : Bool = @tls_verify, name : String = @name,
                    prefix : String = @prefix) : Config
        Config.new(url, pool_size, checkout_timeout, connect_timeout, command_timeout, health_check_after, retry,
          tls_ca_file, tls_verify, name, prefix)
      end

      # What decides whether two configs can share a pool. It holds the password: never log it.
      def pool_key : PoolKey
        {@url, @pool_size, @checkout_timeout, @connect_timeout, @command_timeout, @health_check_after, @tls_ca_file, @tls_verify}
      end

      # The URL with its password replaced by `***`.
      def redacted_url : String
        Config.redact(@url)
      end

      def self.redact(url : String) : String
        uri = URI.parse(url)
        return url unless uri.password
        user = uri.user
        credentials = user ? "#{user}:***@" : ":***@"
        authority = "#{uri.host}#{uri.port.try { |port| ":#{port}" }}"
        "#{uri.scheme}://#{credentials}#{authority}#{uri.path}"
      rescue URI::Error
        "redis://***"
      end

      def tls? : Bool
        URI.parse(@url).scheme == "rediss"
      rescue URI::Error
        false
      end

      # A TLS context when `tls_ca_file` or `tls_verify` ask for one; otherwise the shard builds its default for `rediss://`.
      def ssl_context : OpenSSL::SSL::Context::Client?
        return unless tls?
        return if @tls_ca_file.nil? && @tls_verify
        context = OpenSSL::SSL::Context::Client.new
        @tls_ca_file.try { |path| context.ca_certificates = path }
        unless @tls_verify
          # Once per URL, not per connection: a pool opens many
          first = WARNED_MUTEX.synchronize { WARNED_UNVERIFIED.add?(@url) }
          Log.for("Azu::Redis").warn { "REDIS_TLS_VERIFY is off: the certificate of #{redacted_url} is not checked, so the connection can be intercepted" } if first
          context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
        context
      end

      # Opens a new connection. *command_timeout* nil leaves reads unbounded, which a subscriber needs.
      def connect(command_timeout : Time::Span? = @command_timeout, name : String = @name) : ::Redis
        redis = ::Redis.new(url: @url, ssl_context: ssl_context, connect_timeout: @connect_timeout,
          command_timeout: command_timeout, reconnect: false)
        begin
          redis.command(["CLIENT", "SETNAME", "azu-#{name}"])
        rescue ex : ::Redis::ConnectionError
          redis.close
          raise ex
        rescue ::Redis::Error
          # An old or restricted server without CLIENT SETNAME still works, only unnamed.
        end
        redis
      end

      def to_s(io : IO) : Nil
        io << "#<Azu::Redis::Config url=" << redacted_url << " pool_size=" << @pool_size << " name=" << @name << '>'
      end

      def inspect(io : IO) : Nil
        to_s(io)
      end

      private def self.first_url(names : Array(String), env : Source) : String
        names.each { |name| env[name]?.presence.try { |url| return url } }
        env["REDIS_URL"]?.presence || DEFAULT_URL
      end

      private def self.env_int(env : Source, name : String, default : Int32) : Int32
        return default unless value = env[name]?.presence
        value.to_i? || raise ArgumentError.new("#{name} must be an integer")
      end

      private def self.env_seconds(env : Source, name : String, default : Time::Span) : Time::Span
        return default unless value = env[name]?.presence
        seconds = value.to_f? || raise ArgumentError.new("#{name} must be a number of seconds")
        raise ArgumentError.new("#{name} must be positive") unless seconds > 0
        seconds.seconds
      end
    end
  end
end

require "redis"
require "./clock"
require "./redis/*"

module Azu
  # The one place Azu opens Redis connections. `Azu::Cache::RedisStore`, `Azu::PubSub::Redis` and
  # `Azu::Presence::Store::Redis` all take a `Client`, so they share a pool, a URL, timeouts and a retry policy.
  # Acquiring with an equal config (`Config#pool_key`) returns a handle on the same pool; the pool closes when its
  # last handle does, or on `shutdown`.
  #
  # Nothing connects at require time or when a client is built: connections open on first use.
  module Redis
    # Raised for any use of a pool that was closed.
    class ClosedError < ::Redis::Error
    end

    class Shared
      getter pool : Client::ConnectionPool
      property handles : Int32 = 0

      def initialize(@pool : Client::ConnectionPool)
      end
    end

    @@shared = {} of Config::PoolKey => Shared
    @@mutex = Mutex.new

    # A handle on the pool for *config*, opening it first if no live handle shares its settings.
    def self.acquire(config : Config = Config.from_env) : Client
      key = config.pool_key
      shared = @@mutex.synchronize do
        entry = @@shared[key]?
        entry = @@shared[key] = Shared.new(build_pool(config)) if entry.nil? || entry.pool.closed?
        entry.handles += 1
        entry
      end
      Client.new(config, shared.pool, -> { release(key, shared) })
    end

    # Closes every shared pool; handles then raise `ClosedError`. `Azu.shutdown` calls this after Presence and PubSub stop.
    def self.shutdown : Nil
      pools = @@mutex.synchronize { @@shared.values.tap { @@shared.clear } }
      pools.each(&.pool.close)
    end

    # Pools currently shared, for diagnostics and specs.
    def self.shared_count : Int32
      @@mutex.synchronize { @@shared.size }
    end

    def self.build_pool(config : Config) : Client::ConnectionPool
      Client::ConnectionPool.new(config.pool_size, config.checkout_timeout, -> { config.connect },
        config.health_check_after, ->(connection : ::Redis) { connection.ping == "PONG" },
        ->(error : Exception) { connection_failure?(error) })
    end

    # True when *error* means the connection can no longer be trusted (lost, refused, timed out, TLS failure).
    def self.connection_failure?(error : Exception) : Bool
      error.is_a?(::Redis::ConnectionError | IO::Error | OpenSSL::Error)
    end

    # True when a command timed out. The `redis` shard reports a read timeout as a `ConnectionLostError` whose
    # message starts with `IO::TimeoutError`.
    def self.timeout?(error : Exception) : Bool
      return true if error.is_a?(IO::TimeoutError)
      error.is_a?(::Redis::ConnectionLostError) && error.message.try(&.starts_with?("IO::TimeoutError")) == true
    end

    # True when running the command again on a fresh connection is safe to try: the connection failed, but the
    # command did not merely time out (it may then have been applied).
    def self.retryable?(error : Exception) : Bool
      connection_failure?(error) && !timeout?(error)
    end

    private def self.release(key, shared : Shared) : Nil
      close = @@mutex.synchronize do
        shared.handles -= 1
        next false unless shared.handles <= 0
        @@shared.delete(key) if @@shared[key]? == shared
        true
      end
      shared.pool.close if close
    end
  end
end

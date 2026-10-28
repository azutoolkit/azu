require "./store"
require "./memory"
require "../../redis"

module Azu
  module Handler
    class Throttle
      class Store
        # The counters in Redis, shared by every instance of the app: a client's requests are counted in one key
        # (`<prefix>c:<client>`, which expires with the window) and a block is one key (`<prefix>b:<client>`, which
        # expires with the block), both moved in one Lua script, so two instances counting the same client at once
        # cannot lose a request or block it twice. Time is Redis's: a block outlives a restart of the app. The two
        # keys of a client share no hash tag, so Redis Cluster is not supported (`Azu::Redis` has no Cluster client).
        #
        # Redis is asked with short timeouts (`TIMEOUT`) and no retry, since the handler is first in the stack and
        # every request waits for the answer. When Redis fails or is too slow, the client is counted in a memory store
        # of this process instead, and Redis is left alone for `BACKOFF` before it is asked again: the limit degrades
        # to per-instance counting rather than disappearing, and a Redis outage never stalls the app. Each failure
        # window logs one warning.
        class Redis < Store
          DEFAULT_PREFIX = "azu:throttle:"
          # Pooled connections when built from a URL or the environment.
          POOL_SIZE = 4
          # How long a request waits for Redis (to connect, for a pooled connection, for the answer).
          TIMEOUT = 250.milliseconds
          # How long Redis is left alone after a failure.
          BACKOFF = 2.seconds

          # KEYS[1] the counter, KEYS[2] the block; ARGV interval, threshold, duration (seconds). Answers the seconds
          # a block has left (a block in force), the negated duration (blocked by this request) or 0 (let through).
          SCRIPT = <<-LUA
            local left = redis.call('PTTL', KEYS[2])
            if left > 0 then return math.ceil(left / 1000) end
            local count = redis.call('INCR', KEYS[1])
            if count == 1 or redis.call('TTL', KEYS[1]) < 0 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
            if count > tonumber(ARGV[2]) then
              redis.call('SET', KEYS[2], '1', 'EX', ARGV[3])
              redis.call('DEL', KEYS[1])
              return -tonumber(ARGV[3])
            end
            return 0
            LUA

          # `THROTTLE_REDIS_URL`, then `REDIS_URL`, then localhost.
          def self.default_url : String
            Azu::Redis::Config.url_from_env("THROTTLE_REDIS_URL")
          end

          # On the shared pool for the URL `THROTTLE_REDIS_URL` (then `REDIS_URL`) names, with the TLS and prefix
          # settings of `REDIS_*` but the throttle's own pool size, timeouts and no retry.
          def self.from_env : Redis
            base = Azu::Redis::Config.from_env(url_names: ["THROTTLE_REDIS_URL"])
            new(base.url, DEFAULT_PREFIX, tls_ca_file: base.tls_ca_file, tls_verify: base.tls_verify?)
          end

          def initialize(url : String, prefix : String = DEFAULT_PREFIX, *, tls_ca_file : String? = nil, tls_verify : Bool = true)
            config = Azu::Redis::Config.new(url: url, pool_size: POOL_SIZE, checkout_timeout: TIMEOUT, connect_timeout: TIMEOUT,
              command_timeout: TIMEOUT, retry: Azu::Redis::Retry.new(retries: 0), tls_ca_file: tls_ca_file, tls_verify: tls_verify)
            initialize(Azu::Redis.acquire(config), prefix)
          end

          # On *client* as given: its timeouts are the request's wait when Redis hangs, so keep them short.
          def initialize(@client : Azu::Redis::Client, @prefix : String = DEFAULT_PREFIX, @log : ::Log = ::Log.for("Azu::Handler::Throttle"))
            @fallback = Memory.new
            @retry_at = Atomic(Int64).new(Int64::MIN) # the `Clock.coarse_nanoseconds` reading Redis is asked again at
          end

          def hit(key : String, limits : Limits) : Verdict
            return @fallback.hit(key, limits) if backing_off?

            answer = @client.run("throttle") do |redis|
              redis.eval(SCRIPT, [counter_key(key), block_key(key)], [limits.interval, limits.threshold, limits.duration])
            end
            verdict(answer.as(Int64).to_i32)
          rescue error : ::Redis::Error | IO::Error | OpenSSL::Error
            back_off(error)
            @fallback.hit(key, limits)
          end

          # Deletes every counter and block under the prefix; `SCAN`s the keyspace, so for specs and operators, not
          # requests. The memory fallback is cleared too.
          def reset : Nil
            @fallback.reset
            cursor = "0"
            loop do
              reply = @client.run("throttle.reset") { |redis| redis.scan(cursor, match: "#{@prefix}*", count: 500) }.as(Array)
              cursor = reply[0].as(String)
              keys = reply[1].as(Array)
              @client.run("throttle.reset") { |redis| redis.del(keys.map(&.as(String))) } unless keys.empty?
              break if cursor == "0"
            end
          end

          # True while Redis is left alone after a failure.
          def backing_off? : Bool
            Clock.coarse_nanoseconds < @retry_at.get
          end

          private def verdict(seconds : Int32) : Verdict
            case
            when seconds > 0 then Verdict.new(seconds)
            when seconds < 0 then Verdict.new(-seconds, Verdict::Event::Blocked)
            else                  Verdict.new
            end
          end

          private def back_off(error : Exception) : Nil
            @retry_at.set(Clock.coarse_nanoseconds + BACKOFF.total_nanoseconds.to_i64)
            @log.warn(exception: error) { "throttle store unavailable: counting in this process alone for #{BACKOFF.total_seconds.to_i} seconds" }
          end

          private def counter_key(client : String) : String
            "#{@prefix}c:#{client}"
          end

          private def block_key(client : String) : String
            "#{@prefix}b:#{client}"
          end
        end
      end
    end
  end
end

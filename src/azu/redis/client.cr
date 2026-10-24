require "./config"
require "./pool"

module Azu
  module Redis
    # One handle on a Redis server for a whole app: a bounded pool of connections plus the rules for using them.
    # Cache, PubSub and Presence all go through one (see `Azu::Redis.acquire`), so they share connections, URL,
    # timeouts and retry policy instead of each opening its own.
    #
    # ```
    # redis = Azu::Redis.acquire(Azu::Redis::Config.from_env)
    # redis.run { |connection| connection.set("greeting", "hello") }
    # redis.multi { |transaction| transaction.incr("hits") }
    # redis.ping # => true
    # redis.close
    # ```
    #
    # `run` borrows a connection. When the connection turns out to be dead (reset, restarted server, idle drop) it
    # is discarded and, with `retry: true`, the block runs again on a fresh one, as often as `Config#retry`
    # allows, waiting a bounded, jittered time between attempts. Retrying is opt-in because the block runs twice:
    # pass it for idempotent commands only. A command that merely timed out is not retried (it may have been
    # applied) but its connection is discarded, since a late reply would answer the wrong command. Timeouts are
    # per socket read and write (`Config#command_timeout`), not a deadline for the whole call.
    #
    # A lost connection also closes the other idle connections, which are most likely dead as well (a restarted
    # server), so the next attempt, retried or not, opens a fresh one. Only connections that were already idle when
    # the failed attempt started are closed, so a connection another fiber checked in since stays. When two fibers
    # fail together, that leaves such a connection possibly dead for the second one: give `Config#retry` at least 2
    # retries if many fibers share the client across restarts.
    class Client
      alias ConnectionPool = Pool(::Redis)

      getter config : Config

      # *on_close* runs once on `close`; a view made by `with_prefix` has none, so it never closes the shared pool.
      def initialize(@config : Config, @pool : ConnectionPool, @on_close : Proc(Nil)? = nil)
        @close_lock = Mutex.new
      end

      # A client with a pool of its own, closed by `close`. Most code wants `Azu::Redis.acquire`, which shares.
      def self.new(config : Config) : Client
        pool = Redis.build_pool(config)
        new(config, pool, -> { pool.close })
      end

      # Runs the block with a pooled connection. *operation* names the call for `Instrumentation.redis`.
      def run(operation : String = "command", retry : Bool = false, & : ::Redis -> T) : T forall T
        Instrumentation.redis(operation, @config.name) { attempt(retry) { |connection| yield connection } }
      end

      # Runs the commands the block issues on the transaction in one `MULTI`/`EXEC`.
      # The block may run twice if the connection fails and the call is retried: only issue commands in it.
      # The connection is discarded after any error, since an error reply inside the transaction leaves the other
      # replies unread on the socket.
      def multi(operation : String = "multi", retry : Bool = false, & : ::Redis::TransactionApi -> _) : Array(::Redis::RedisValue)
        Instrumentation.redis(operation, @config.name) do
          attempt(retry, strict: true) { |connection| connection.multi { |transaction| yield transaction } }
        end
      end

      # Sends the commands the block issues on the pipeline in one round trip.
      # The connection is discarded after any error, as for `multi`.
      def pipelined(operation : String = "pipeline", retry : Bool = false, & : ::Redis::PipelineApi -> _) : Array(::Redis::RedisValue)
        Instrumentation.redis(operation, @config.name) do
          attempt(retry, strict: true) { |connection| connection.pipelined { |pipeline| yield pipeline } }
        end
      end

      # A connection of its own that is not taken from the pool, for something that holds it for good: a
      # `SUBSCRIBE` loop, or a blocking command such as `BLPOP` or `XREAD BLOCK` that outlasts `command_timeout`.
      # Reads are unbounded unless *command_timeout* is given. `close` ends it with the client; `release` ends
      # it earlier.
      def dedicated(command_timeout : Time::Span? = nil, name : String = "#{@config.name}-subscriber") : ::Redis
        @pool.adopt(@config.connect(command_timeout, name))
      end

      def release(connection : ::Redis) : Nil
        @pool.release_adopted(connection)
      end

      # The Redis server's clock (`TIME`), so nodes that write and judge expiry need no synchronized clocks.
      def time : Time
        seconds, micros = run("time", retry: true, &.command(["TIME"])).as(Array).map(&.as(String).to_i64)
        Time.unix(seconds) + micros.microseconds
      end

      # True when the server answers `PING`; never raises.
      def ping : Bool
        run("ping", retry: false, &.ping) == "PONG"
      rescue
        false
      end

      # A check for `Azu::Handler::HealthCheck`: `checks: {"redis" => redis.health_check}`.
      def health_check : Proc(Bool)
        -> { ping }
      end

      def stats : ConnectionPool::Stats
        @pool.stats
      end

      # *name* under this client's key prefix.
      def key(name : String) : String
        "#{@config.prefix}#{name}"
      end

      # A view of this client whose `key` uses *prefix*; the pool, and its lifetime, stay shared.
      def with_prefix(prefix : String) : Client
        Client.new(@config.copy_with(prefix: prefix), @pool)
      end

      def closed? : Bool
        @pool.closed?
      end

      # Gives this handle back. The pool closes with its last handle (see `Azu::Redis.acquire`), after which the
      # client raises `Pool::ClosedError`. Closing twice does nothing.
      def close : Nil
        callback = @close_lock.synchronize { @on_close.tap { @on_close = nil } }
        callback.try(&.call)
      end

      def to_s(io : IO) : Nil
        io << "#<Azu::Redis::Client url=" << @config.redacted_url << " name=" << @config.name << '>'
      end

      def inspect(io : IO) : Nil
        to_s(io)
      end

      private def attempt(retry : Bool, strict : Bool = false, & : ::Redis -> T) : T forall T
        tries = 0
        loop do
          return once(strict) { |connection| yield connection }
        rescue ex
          raise ex unless retry && Redis.retryable?(ex) && @config.retry.retry?(tries)
          Clock.sleep(@config.retry.delay(tries))
          tries += 1
        end
      end

      # One try. A lost connection also closes the idle ones that were already idle when it started.
      private def once(strict : Bool, & : ::Redis -> T) : T forall T
        started = Clock.instant
        begin
          @pool.run(strict) { |connection| yield connection }
        rescue ex
          @pool.drop_idle(started) if Redis.retryable?(ex)
          raise ex
        end
      end
    end
  end
end

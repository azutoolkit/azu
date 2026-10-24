require "redis"
require "./backend"
require "./subscribers"

module Azu
  module PubSub
    # Redis backend: broadcasts reach every node, so Spark views and channels stay in sync
    # across processes.
    #
    # Nothing connects until the first `subscribe` or `broadcast`. One dedicated connection (not taken from
    # the pool) listens on `PSUBSCRIBE <prefix>*`, reconnecting with bounded, jittered backoff, and fans messages
    # out to the local subscribers; publishes go through the shared `Azu::Redis::Client` pool.
    #
    # Built from a URL it acquires the shared client for it (so the cache and presence on the same Redis share
    # its pool); pass a *client* to choose one yourself. A client you pass is yours to close.
    class Redis < Backend
      DEFAULT_PREFIX = "azu:pubsub:"
      MAX_BACKOFF    = 15.seconds
      # Upper bound for connecting and for each publish, so a hung Redis cannot hold a broadcaster
      # indefinitely.
      PUBLISH_TIMEOUT = 5.seconds
      # Pooled connections for publishing when built from a URL: publishes are short, so a few are plenty.
      POOL_SIZE = 2
      # How long the very first `subscribe` waits for Redis to confirm the pattern subscription.
      LISTEN_TIMEOUT = 2.seconds

      # `PUBSUB_REDIS_URL`, then `REDIS_URL`, then localhost.
      def self.default_url : String
        Azu::Redis::Config.url_from_env("PUBSUB_REDIS_URL")
      end

      def initialize(url : String = Redis.default_url, prefix : String = DEFAULT_PREFIX)
        config = Azu::Redis::Config.new(url: url, pool_size: POOL_SIZE, connect_timeout: PUBLISH_TIMEOUT, command_timeout: PUBLISH_TIMEOUT)
        initialize(Azu::Redis.acquire(config), prefix, true)
      end

      def initialize(@client : Azu::Redis::Client, @prefix : String = DEFAULT_PREFIX, @owned : Bool = false)
        @subscribers = Subscribers.new
        @mutex = Mutex.new
        @listener = nil.as(::Redis?)
        @done = ::Channel(Nil).new
        @listening = false
        @waited = false
        @confirmed = ::Channel(Nil).new
      end

      def subscribe(topic : String, &handler : Message ->) : Subscription
        subscription = Subscription.new(topic, self, &handler)
        @subscribers.add(subscription)
        ensure_listening
        await_first_confirmation
        subscription
      end

      def unsubscribe(subscription : Subscription) : Nil
        @subscribers.remove(subscription)
      end

      # A dead connection is discarded and the publish retried on a fresh one, as `Azu::Redis::Config#retry`
      # allows; a failure past that surfaces.
      def broadcast(topic : String, payload : String) : Nil
        @client.run("publish", retry: true) { |redis| redis.publish(channel_for(topic), payload) }
      end

      def shutdown : Nil
        return if @done.closed?
        @done.close
        listener = @mutex.synchronize { @listener.tap { @listener = nil } }
        listener.try { |connection| @client.release(connection) }
        @subscribers.clear
        @client.close if @owned
      end

      # The first `subscribe` of a backend returns once Redis has confirmed the pattern subscription (or after
      # `LISTEN_TIMEOUT`), so a broadcast right after it, from any node, reaches that subscriber. Later
      # subscriptions only add a local handler and never wait.
      private def await_first_confirmation : Nil
        first = @mutex.synchronize { @waited.tap { @waited = true } == false }
        return unless first
        select
        when @confirmed.receive?
        when timeout(LISTEN_TIMEOUT)
        end
      end

      private def confirm_listening : Nil
        @mutex.synchronize { @confirmed.close unless @confirmed.closed? }
      end

      private def ensure_listening : Nil
        @mutex.synchronize do
          return if @listening || @done.closed?
          @listening = true
          spawn(name: "azu-pubsub-redis") { listen }
        end
      end

      # Runs until `shutdown`: a dropped connection is retried with exponential backoff.
      private def listen : Nil
        policy = Azu::Redis::Retry.forever(max: MAX_BACKOFF)
        attempt = 0
        until @done.closed?
          begin
            listen_once
            attempt = 0
          rescue ex
            Log.for("Azu::PubSub").warn(exception: ex) { "Redis listener lost, retrying" } unless @done.closed?
          end
          break unless wait(policy.delay(attempt))
          attempt += 1
        end
      end

      private def listen_once : Nil
        listener = @client.dedicated(name: "pubsub-listener")
        @mutex.synchronize { @listener = listener }
        begin
          return if @done.closed?
          listener.psubscribe("#{@prefix}*") do |on|
            on.psubscribe { |_pattern, _count| confirm_listening }
            on.pmessage { |_pattern, channel, payload| dispatch(channel, payload) }
          end
        ensure
          @mutex.synchronize { @listener = nil if @listener == listener }
          @client.release(listener)
        end
      end

      private def dispatch(channel : String, payload : String) : Nil
        @subscribers.dispatch(Message.new(channel.lchop(@prefix), payload))
      end

      # false once the backend is shut down.
      private def wait(span : Time::Span) : Bool
        select
        when @done.receive?
          false
        when timeout(span)
          true
        end
      end

      private def channel_for(topic : String) : String
        "#{@prefix}#{topic}"
      end
    end
  end
end

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

      def initialize(url : String = Redis.default_url, prefix : String = DEFAULT_PREFIX, listen_timeout : Time::Span = LISTEN_TIMEOUT)
        config = Azu::Redis::Config.new(url: url, pool_size: POOL_SIZE, connect_timeout: PUBLISH_TIMEOUT, command_timeout: PUBLISH_TIMEOUT)
        initialize(Azu::Redis.acquire(config), prefix, true, listen_timeout)
      end

      def initialize(@client : Azu::Redis::Client, @prefix : String = DEFAULT_PREFIX, @owned : Bool = false, @listen_timeout : Time::Span = LISTEN_TIMEOUT)
        @subscribers = Subscribers.new
        @mutex = Mutex.new
        @listener = nil.as(::Redis?)
        @done = ::Channel(Nil).new
        @listening = false
        @gave_up = false
        @confirmed = ::Channel(Nil).new
      end

      def subscribe(topic : String, &handler : Message ->) : Subscription
        subscription = Subscription.new(topic, self, &handler)
        @subscribers.add(subscription)
        ensure_listening
        await_confirmation
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
        confirm_listening
        listener = @mutex.synchronize { @listener.tap { @listener = nil } }
        listener.try { |connection| @client.release(connection) }
        @subscribers.clear
        @client.close if @owned
      end

      # Until Redis has confirmed the pattern subscription a broadcast would be lost, so `subscribe` returns only
      # after the confirmation (every subscriber, including ones that subscribe at the same moment as the first;
      # once confirmed the wait is instant). If it does not come within the listen timeout, a warning is logged and
      # later subscribers stop waiting until it does, so a Redis that is down costs one wait, not one per subscriber.
      private def await_confirmation : Nil
        return if @done.closed? || @mutex.synchronize { @gave_up }
        select
        when @confirmed.receive?
        when timeout(@listen_timeout)
          give_up
        end
      end

      private def give_up : Nil
        first = @mutex.synchronize { !@gave_up && !@confirmed.closed? && (@gave_up = true) }
        Log.for("Azu::PubSub").warn { "Redis did not confirm the subscription within #{@listen_timeout.total_seconds}s; broadcasts made now may be lost" } if first
      end

      private def confirm_listening : Nil
        @mutex.synchronize do
          @gave_up = false
          @confirmed.close unless @confirmed.closed?
        end
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

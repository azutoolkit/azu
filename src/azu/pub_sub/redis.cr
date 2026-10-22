require "redis"
require "./backend"
require "./subscribers"

module Azu
  module PubSub
    # Redis backend: broadcasts reach every node, so Spark views and channels stay in sync
    # across processes.
    #
    # Nothing connects until the first `subscribe` or `broadcast`. One dedicated connection
    # listens on `PSUBSCRIBE <prefix>*` (reconnecting with backoff) and fans messages out to the
    # local subscribers; a second, mutex-guarded connection publishes.
    class Redis < Backend
      DEFAULT_PREFIX = "azu:pubsub:"
      MAX_BACKOFF    = 15.seconds

      def initialize(@url : String = ENV.fetch("PUBSUB_REDIS_URL", "redis://localhost:6379/0"),
                     @prefix : String = DEFAULT_PREFIX)
        @subscribers = Subscribers.new
        @mutex = Mutex.new
        @publisher = nil.as(::Redis?)
        @listener = nil.as(::Redis?)
        @done = ::Channel(Nil).new
        @listening = false
      end

      def subscribe(topic : String, &handler : Message ->) : Subscription
        subscription = Subscription.new(topic, self, &handler)
        @subscribers.add(subscription)
        ensure_listening
        subscription
      end

      def unsubscribe(subscription : Subscription) : Nil
        @subscribers.remove(subscription)
      end

      def broadcast(topic : String, payload : String) : Nil
        @mutex.synchronize do
          publisher = (@publisher ||= connect)
          publisher.publish(channel_for(topic), payload)
        end
      end

      def shutdown : Nil
        return if @done.closed?
        @done.close
        @mutex.synchronize do
          @listener.try(&.close)
          @publisher.try(&.close)
          @listener = @publisher = nil
        end
        @subscribers.clear
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
        backoff = 0.5.seconds
        until @done.closed?
          begin
            listen_once
            backoff = 0.5.seconds
          rescue ex
            Log.for("Azu::PubSub").warn(exception: ex) { "Redis listener lost, retrying in #{backoff}" } unless @done.closed?
          end
          break unless wait(backoff)
          backoff = {backoff * 2, MAX_BACKOFF}.min
        end
      end

      private def listen_once : Nil
        listener = connect
        @mutex.synchronize { @listener = listener }
        listener.psubscribe("#{@prefix}*") do |on|
          on.pmessage { |_pattern, channel, payload| dispatch(channel, payload) }
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

      private def connect : ::Redis
        ::Redis.new(url: @url, reconnect: false)
      end

      private def channel_for(topic : String) : String
        "#{@prefix}#{topic}"
      end
    end
  end
end

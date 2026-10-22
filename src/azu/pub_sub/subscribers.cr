module Azu
  module PubSub
    # Thread-safe table of the subscriptions held by this process, shared by the backends.
    class Subscribers
      def initialize
        @topics = {} of String => Array(Subscription)
        @mutex = Mutex.new
      end

      def add(subscription : Subscription) : Nil
        @mutex.synchronize do
          (@topics[subscription.topic] ||= [] of Subscription) << subscription
        end
      end

      def remove(subscription : Subscription) : Nil
        @mutex.synchronize do
          next unless list = @topics[subscription.topic]?
          list.reject! { |candidate| candidate.same?(subscription) }
          @topics.delete(subscription.topic) if list.empty?
        end
      end

      # Delivers outside the lock so handlers may (un)subscribe freely.
      def dispatch(message : Message) : Nil
        snapshot = @mutex.synchronize { @topics[message.topic]?.try(&.dup) }
        snapshot.try(&.each(&.deliver(message)))
      end

      def size : Int32
        @mutex.synchronize { @topics.sum { |_, list| list.size } }
      end

      def clear : Nil
        @mutex.synchronize { @topics.clear }
      end
    end
  end
end

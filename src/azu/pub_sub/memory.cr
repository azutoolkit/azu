require "./backend"
require "./subscribers"

module Azu
  module PubSub
    # In-process backend: zero dependencies, no fibers, single node only.
    class Memory < Backend
      def initialize
        @subscribers = Subscribers.new
      end

      def subscribe(topic : String, &handler : Message ->) : Subscription
        subscription = Subscription.new(topic, self, &handler)
        @subscribers.add(subscription)
        subscription
      end

      def unsubscribe(subscription : Subscription) : Nil
        @subscribers.remove(subscription)
      end

      def broadcast(topic : String, payload : String) : Nil
        @subscribers.dispatch(Message.new(topic, payload))
      end

      def subscriber_count : Int32
        @subscribers.size
      end

      def shutdown : Nil
        @subscribers.clear
      end
    end
  end
end

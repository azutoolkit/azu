module Azu
  module PubSub
    # Handle returned by `PubSub.subscribe`. Cancel it to stop deliveries.
    class Subscription
      getter topic : String

      def initialize(@topic : String, @backend : Backend, &@handler : Message ->)
        @cancelled = Atomic(Int32).new(0)
      end

      def cancelled? : Bool
        @cancelled.get == 1
      end

      # Idempotent; no message is delivered once it returns.
      def cancel : Nil
        return unless @cancelled.compare_and_set(0, 1).last
        @backend.unsubscribe(self)
      end

      def deliver(message : Message) : Nil
        return if cancelled?
        @handler.call(message)
      rescue ex
        Log.for("Azu::PubSub").error(exception: ex) { "Subscriber of #{topic} raised" }
      end
    end
  end
end

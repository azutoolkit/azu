module Azu
  module Presence
    # A claim on a topic being watched by a `Tracker`. The tracker follows a topic while at least one claim is
    # open; `cancel` (idempotent) gives the claim back.
    class Watch
      def initialize(@tracker : Tracker, @topic : String, @token : Int64)
        @cancelled = Atomic(Int32).new(0)
      end

      def cancelled? : Bool
        @cancelled.get == 1
      end

      def cancel : Nil
        return unless @cancelled.compare_and_set(0, 1).last
        @tracker.release_watch(@topic, @token)
      end
    end

    # What `Presence.subscribe` returns: cancelling it stops the deliveries and gives the watch back.
    class Subscription
      def initialize(@events : PubSub::Subscription, @watch : Watch)
      end

      def cancelled? : Bool
        @events.cancelled?
      end

      def cancel : Nil
        @events.cancel
        @watch.cancel
      end
    end
  end
end

module Azu
  module PubSub
    # A subscribe that is in flight for one topic of a `Channel` or a `Spark::Session`. A backend may wait before it
    # returns (a Redis backend waits for Redis to confirm the first subscription), so the topic is reserved first
    # and the lock is not held across the call. Others that want the topic wait for `finish`, then look at how it
    # ended: `cancelled?` (an unsubscribe came in meanwhile) means leave it alone, `error` means fail with the same
    # error instead of trying again.
    class Reservation
      getter owner : Fiber = Fiber.current
      getter error : Exception? = nil

      def initialize
        @done = ::Channel(Nil).new
        @cancelled = false
      end

      def cancel : Nil
        @cancelled = true
      end

      def cancelled? : Bool
        @cancelled
      end

      def fail(error : Exception) : Nil
        @error = error
      end

      def finish : Nil
        @done.close
      end

      # Blocks until the owner is done. The owner itself never waits (a re-entrant subscribe would deadlock).
      def wait : Nil
        @done.receive? unless owner == Fiber.current
      end

      def owned_by_caller? : Bool
        owner == Fiber.current
      end
    end
  end
end

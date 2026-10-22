module Azu
  module Spark
    # Token bucket: *burst* events may be spent at once, refilled at *rate* events per second.
    class RateLimiter
      def initialize(@rate : Float64, @burst : Int32)
        @tokens = @burst.to_f
        @refilled_at = Time.instant
        @mutex = Mutex.new
      end

      # Spends one token, or returns false when the bucket is empty.
      def allow? : Bool
        @mutex.synchronize do
          refill
          next false if @tokens < 1.0
          @tokens -= 1.0
          true
        end
      end

      private def refill : Nil
        now = Time.instant
        @tokens = {@burst.to_f, @tokens + (now - @refilled_at).total_seconds * @rate}.min
        @refilled_at = now
      end
    end
  end
end

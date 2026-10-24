module Azu
  module Redis
    # How many times a command is tried again after a lost connection, and how long to wait before each
    # attempt: exponential from *base*, capped at *max*, shortened by up to *jitter* (a fraction between 0 and
    # 1) so that many clients that lose a connection together do not come back together.
    #
    # The wait goes through `Azu::Clock.sleep`, so a spec with a `Clock::Fake` retries without sleeping.
    struct Retry
      getter retries : Int32
      getter base : Time::Span
      getter max : Time::Span
      getter jitter : Float64

      def initialize(@retries : Int32 = 1, @base : Time::Span = 10.milliseconds, @max : Time::Span = 1.second, @jitter : Float64 = 0.5)
        raise ArgumentError.new("retries must not be negative") if @retries < 0
        raise ArgumentError.new("jitter must be between 0 and 1") unless 0.0 <= @jitter <= 1.0
      end

      def self.none : Retry
        new(retries: 0)
      end

      # A policy for a loop that must never give up (a subscriber reconnecting).
      def self.forever(base : Time::Span = 500.milliseconds, max : Time::Span = 15.seconds) : Retry
        new(retries: Int32::MAX, base: base, max: max)
      end

      # The wait before retry number *attempt* (0 for the first). *random* is in [0, 1) and picks the point in the
      # jitter band; specs pass it for a deterministic answer.
      def delay(attempt : Int32, random : Float64 = rand) : Time::Span
        ceiling = {@base * (1_i64 << attempt.clamp(0, 30)), @max}.min
        ceiling * (1.0 - @jitter * random)
      end

      def retry?(attempt : Int32) : Bool
        attempt < @retries
      end
    end
  end
end

module Azu
  # The time source behind everything that expires: cache TTLs, throttle windows, token lifetimes, rate limits.
  # It reads the system clock; specs swap in a `Clock::Fake` and advance it instead of sleeping.
  #
  # Use `instant` (monotonic) for anything that measures elapsed time, such as TTLs and windows, and `now`
  # only for wall-clock values that are serialized, such as token expiry and timestamps.
  #
  # `source=` and `use` replace one process-wide source: they are a seam for specs, not for production code,
  # and swapping while other fibers read the clock is not supported.
  module Clock
    abstract class Source
      abstract def now : Time
      abstract def instant : Time::Instant
    end

    class System < Source
      def now : Time
        Time.utc
      end

      def instant : Time::Instant
        Time.instant
      end
    end

    # A clock that only moves when told to.
    class Fake < Source
      def initialize(@start : Time = Time.utc)
        @origin = Time.instant
        @elapsed = Time::Span.zero
        @wall_step = Time::Span.zero
        @mutex = Mutex.new
      end

      def now : Time
        @mutex.synchronize { @start + @elapsed + @wall_step }
      end

      def instant : Time::Instant
        @origin + elapsed
      end

      def advance(span : Time::Span) : Nil
        @mutex.synchronize { @elapsed += span }
      end

      # Steps the wall clock (`now`) alone, like an NTP or manual adjustment; `instant` does not move.
      def step_wall_clock(span : Time::Span) : Nil
        @mutex.synchronize { @wall_step += span }
      end

      private def elapsed : Time::Span
        @mutex.synchronize { @elapsed }
      end
    end

    @@source : Source = System.new

    def self.source : Source
      @@source
    end

    def self.source=(source : Source) : Source
      @@source = source
    end

    def self.now : Time
      @@source.now
    end

    def self.instant : Time::Instant
      @@source.instant
    end

    # Runs the block with *source* installed, restoring the previous one afterwards.
    def self.use(source : Source, &)
      previous = @@source
      @@source = source
      begin
        yield source
      ensure
        @@source = previous
      end
    end
  end
end

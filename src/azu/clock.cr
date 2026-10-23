module Azu
  # The time source behind everything that expires: cache TTLs, throttle windows, token lifetimes, rate limits.
  # It reads the system clock; specs swap in a `Clock::Fake` and advance it instead of sleeping.
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
        @mutex = Mutex.new
      end

      def now : Time
        @start + elapsed
      end

      def instant : Time::Instant
        @origin + elapsed
      end

      def advance(span : Time::Span) : Nil
        @mutex.synchronize { @elapsed += span }
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

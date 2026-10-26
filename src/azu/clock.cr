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

      # A monotonic reading in nanoseconds that may lag `instant` by up to one timer tick (1-10 ms) and is cheaper to
      # read, for checks with a far longer interval (Static looks at its directory at most once a second). Compare it
      # only with other `coarse_nanoseconds` readings: its origin is unspecified. By default it follows `instant`.
      def coarse_nanoseconds : Int64
        elapsed = instant - INSTANT_ORIGIN
        elapsed.to_i * 1_000_000_000 + elapsed.nanoseconds
      end

      private INSTANT_ORIGIN = Time.instant

      # Waits for *span*. The system clock sleeps; a fake one advances instead, so retry and backoff code
      # runs in a spec without waiting.
      def sleep(span : Time::Span) : Nil
        ::sleep(span)
      end
    end

    class System < Source
      def now : Time
        Time.utc
      end

      def instant : Time::Instant
        Time.instant
      end

      {% if flag?(:linux) %}
        # CLOCK_MONOTONIC_COARSE: the time of the last timer tick, up to one tick (1-10 ms) old, read without asking
        # the hardware. CLOCK_MONOTONIC, which counts from the same origin, on a kernel without it.
        def coarse_nanoseconds : Int64
          if LibC.clock_gettime(LibC::CLOCK_MONOTONIC_COARSE, out time) != 0
            LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(time))
          end
          time.tv_sec.to_i64 * 1_000_000_000 + time.tv_nsec
        end
      {% end %}
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

      def sleep(span : Time::Span) : Nil
        advance(span)
        Fiber.yield
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

    def self.coarse_nanoseconds : Int64
      @@source.coarse_nanoseconds
    end

    def self.sleep(span : Time::Span) : Nil
      @@source.sleep(span)
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

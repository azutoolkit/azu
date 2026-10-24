module Azu
  module Redis
    # A bounded pool of connections, generic so it can be driven without a server.
    #
    # Capacity is two buffered channels: the idle connections and the permits to open one more. A checkout takes an
    # idle connection first and a permit only when none is idle, so connections are made lazily, only as
    # concurrency needs them, never more than *capacity* exist, and a fiber that finds none free waits for one for
    # at most *checkout_timeout* (then `::Redis::PoolTimeoutError`). A connection that was idle longer than
    # *health_check_after* (on `Azu::Clock`) is probed on checkout and replaced if the probe fails. A connection
    # that failed is `discard`ed and its permit freed, so a waiter can open a fresh one.
    class Pool(T)
      record Stats, capacity : Int32, open : Int32, in_use : Int32, idle : Int32, discarded : Int64, adopted : Int32

      private record Idle(T), connection : T, since : Time::Instant

      getter capacity : Int32

      # *healthy* probes a connection that sat idle; *broken* says whether an exception leaves the connection
      # unusable (it is then discarded rather than reused).
      def initialize(@capacity : Int32, @checkout_timeout : Time::Span, @factory : Proc(T),
                     @health_check_after : Time::Span = 30.seconds,
                     @healthy : Proc(T, Bool) = ->(_connection : T) { true },
                     @broken : Proc(Exception, Bool) = ->(_error : Exception) { true })
        raise ArgumentError.new("capacity must be positive") unless @capacity > 0
        @idle = ::Channel(Idle(T)).new(@capacity)
        @permits = ::Channel(Bool).new(@capacity)
        @mutex = Mutex.new
        @closed = false
        @open = 0
        @in_use = 0
        @discarded = 0_i64
        @adopted = [] of T
        @capacity.times { @permits.send(true) }
      end

      # Yields a connection and gives it back afterwards. A connection is discarded when the block raises an
      # error `broken` accepts (or any error, with *strict*: a half-sent pipeline leaves replies on the socket), and
      # also when the block does not finish at all (`return`, `break`, `next` out of it), since what is left on
      # the connection is then unknown.
      def run(strict : Bool = false, & : T -> R) : R forall R
        connection = checkout
        keep = false
        begin
          result = yield connection
          keep = true
          result
        rescue ex
          keep = !strict && !@broken.call(ex)
          raise ex
        ensure
          keep ? checkin(connection) : discard(connection)
        end
      end

      def checkout : T
        idle = receive
        return open_connection unless idle
        if stale?(idle) && !probe(idle.connection)
          destroy(idle.connection)
          return open_connection
        end
        @mutex.synchronize { @in_use += 1 }
        idle.connection
      end

      def checkin(connection : T) : Nil
        @mutex.synchronize { @in_use -= 1 }
        if closed?
          destroy(connection)
        else
          @mutex.synchronize { @idle.send(Idle(T).new(connection, Clock.instant)) unless @closed }
        end
      end

      # Closes *connection* and frees its permit so another one can be opened.
      def discard(connection : T) : Nil
        @mutex.synchronize do
          @in_use -= 1
          @discarded += 1
        end
        destroy(connection)
        release_permit
      end

      # Opens a connection outside the capacity, for a caller that holds it for good (a subscriber); `close` ends it too.
      def adopt(connection : T) : T
        @mutex.synchronize do
          if @closed
            connection.close
            raise Redis::ClosedError.new("Redis pool is closed")
          end
          @adopted << connection
        end
        connection
      end

      def release_adopted(connection : T) : Nil
        @mutex.synchronize { @adopted.delete(connection) }
        quietly { connection.close }
      end

      def closed? : Bool
        @mutex.synchronize { @closed }
      end

      # Closes the idle connections now and the checked out ones as they come back. Waiters fail with `ClosedError`.
      def close : Nil
        adopted = @mutex.synchronize do
          return if @closed
          @closed = true
          @adopted.dup.tap { @adopted.clear }
        end
        @permits.close
        @idle.close
        adopted.each { |connection| quietly { connection.close } }
        while idle = @idle.receive?
          destroy(idle.connection)
        end
      end

      def stats : Stats
        @mutex.synchronize { Stats.new(@capacity, @open, @in_use, @open - @in_use, @discarded, @adopted.size) }
      end

      # An idle connection, or nil when a permit to open one was taken instead.
      private def receive : Idle(T)?
        select
        when idle = @idle.receive?
          return usable(idle)
        else
        end
        select
        when granted = @permits.receive?
          raise Redis::ClosedError.new("Redis pool is closed") unless granted
          return
        else
        end
        wait_for_either
      end

      private def wait_for_either : Idle(T)?
        select
        when idle = @idle.receive?
          usable(idle)
        when granted = @permits.receive?
          raise Redis::ClosedError.new("Redis pool is closed") unless granted
          nil
        when timeout(@checkout_timeout)
          raise ::Redis::PoolTimeoutError.new("No free Redis connection (#{@capacity} in use) after #{@checkout_timeout.total_seconds}s")
        end
      end

      private def usable(idle : Idle(T)?) : Idle(T)
        if idle.nil? || closed?
          idle.try { |left| destroy(left.connection) }
          raise Redis::ClosedError.new("Redis pool is closed")
        end
        idle
      end

      private def open_connection : T
        connection = @factory.call
        @mutex.synchronize do
          @open += 1
          @in_use += 1
        end
        connection
      rescue ex
        release_permit
        raise ex
      end

      private def stale?(idle : Idle(T)) : Bool
        Clock.instant - idle.since >= @health_check_after
      end

      private def probe(connection : T) : Bool
        @healthy.call(connection)
      rescue
        false
      end

      private def destroy(connection : T) : Nil
        @mutex.synchronize { @open -= 1 }
        quietly { connection.close }
      end

      private def release_permit : Nil
        @mutex.synchronize { @permits.send(true) unless @closed }
      end

      private def quietly(&) : Nil
        yield
      rescue
      end
    end
  end
end

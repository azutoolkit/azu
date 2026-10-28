require "./store"

module Azu
  module Handler
    class Throttle
      class Store
        # The counters in the memory of the process: one table of clients inside their window and one of blocked
        # clients, behind a mutex, judged by `Azu::Clock`'s monotonic instant (an NTP step cannot extend a block).
        #
        # A tracker whose window and block have ended is dropped by a sweep that runs on a request, at most once a
        # second (no fiber). When more than `max_clients` are tracked the oldest ones that are not blocked go first.
        class Memory < Store
          # Thread-safe request tracker structure
          private struct RequestTracker
            property expires : Time::Instant
            property requests : Int32
            property block_expires : Time::Instant?

            def initialize(@expires : Time::Instant, @requests : Int32 = 0, @block_expires : Time::Instant? = nil)
            end

            def block_expired?(current_time : Time::Instant) : Bool
              if block_time = @block_expires
                block_time < current_time
              else
                false
              end
            end

            def watch_expired?(current_time : Time::Instant) : Bool
              @expires <= current_time
            end

            def increment_requests : RequestTracker
              RequestTracker.new(@expires, @requests + 1, @block_expires)
            end

            def block(duration : Int32, current_time : Time::Instant) : RequestTracker
              RequestTracker.new(@expires, @requests, current_time + duration.seconds)
            end
          end

          SWEEP_EVERY = 1.second

          # Clients inside their window, then clients that are blocked. Both keep the order clients entered them in, which
          # is what makes eviction and sweeping cheap: the front of `@tracker` is the oldest first-seen client, and the
          # front of `@blocked` is the block that ends first (every block lasts `duration`).
          @tracker = Hash(String, RequestTracker).new
          @blocked = Hash(String, RequestTracker).new
          @mutex = Mutex.new
          @next_sweep : Time::Instant

          def initialize(@max_clients : Int32 = DEFAULT_MAX_CLIENTS)
            raise ArgumentError.new("max_clients must be positive") unless @max_clients > 0
            @next_sweep = Clock.instant + SWEEP_EVERY
          end

          def hit(key : String, limits : Limits) : Verdict
            @mutex.synchronize { watch(key, limits) }
          end

          def reset : Nil
            @mutex.synchronize do
              @tracker.clear
              @blocked.clear
            end
          end

          def stats : NamedTuple(tracked_ips: Int32, blocked_ips: Int32)
            @mutex.synchronize { {tracked_ips: @tracker.size + @blocked.size, blocked_ips: @blocked.size} }
          end

          # All methods below must be called within @mutex.synchronize block
          private def watch(remote : String, limits : Limits) : Verdict
            current_time = Clock.instant
            sweep(current_time)

            if blocked = @blocked[remote]?
              return still_blocked(remote, blocked, current_time)
            end

            tracker = @tracker[remote]? || begin
              make_room
              RequestTracker.new(current_time + limits.interval.seconds, 0)
            end
            count(remote, tracker.increment_requests, current_time, limits)
          end

          private def still_blocked(remote : String, tracker : RequestTracker, current_time : Time::Instant) : Verdict
            unless tracker.block_expired?(current_time)
              left = tracker.block_expires.try { |ends| (ends - current_time).total_seconds.ceil.to_i32 } || 0
              return Verdict.new(left)
            end

            @blocked.delete(remote)
            Verdict.new(nil, Verdict::Event::Released)
          end

          # Counts one request of a client that is not blocked: a window that has ended starts over, a client over the
          # threshold moves to the blocked table.
          private def count(remote : String, tracker : RequestTracker, current_time : Time::Instant, limits : Limits) : Verdict
            if tracker.watch_expired?(current_time)
              @tracker.delete(remote)
              return Verdict.new
            end

            if tracker.requests > limits.threshold
              @tracker.delete(remote)
              @blocked[remote] = tracker.block(limits.duration, current_time)
              return Verdict.new(limits.duration, Verdict::Event::Blocked)
            end

            @tracker[remote] = tracker
            Verdict.new
          end

          # Drops the trackers whose window has ended, and the blocks that have ended (they are in the order they end in,
          # so only the front is looked at), at most once per SWEEP_EVERY, on a request.
          private def sweep(current_time : Time::Instant) : Nil
            return if current_time < @next_sweep
            @next_sweep = current_time + SWEEP_EVERY
            @tracker.reject! { |_, tracker| tracker.watch_expired?(current_time) }
            while (first = @blocked.first_value?) && first.block_expired?(current_time)
              @blocked.shift
            end
          end

          # A new client does not grow the tables past max_clients: the client first seen longest ago and not blocked goes,
          # and only when every tracked client is blocked, the block that ends first. Both are the front of a table, O(1).
          private def make_room : Nil
            return if @tracker.size + @blocked.size < @max_clients
            @tracker.shift? || @blocked.shift?
          end
        end
      end
    end
  end
end

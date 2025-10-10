module Azu
  module Handler
    # Handler for protecting against Denial-of-service attacks and/or to rate limit requests.
    #
    # DDoS errors occur when the client is sending too many requests at once.
    # these attacks are essentially rate-limiting problems.
    #
    # By blocking a certain IP address, or allowing a certain IP address to make a limited number of
    # requests over a certain period of time, you are building the first line of defense in blocking DDoS attacks.
    # http://en.wikipedia.org/wiki/Denial-of-service_attack.
    #
    # ### Options
    #
    #   * **interval**   Duration in seconds until the request counter is reset. Defaults to 5
    #   * **duration**   Duration in seconds that a remote address will be blocked. Defaults to 900 (15 minutes)
    #   * **threshold**  Number of requests allowed. Defaults to 100
    #   * **blacklist**  Array of remote addresses immediately considered malicious.
    #   * **whitelist**  Array of remote addresses which bypass Deflect.
    #
    # ### Usage
    #
    # ```
    # Azu::Handler::Throttle.new(
    #   interval: 5,
    #   duration: 5,
    #   threshold: 10,
    #   blacklist: ["111.111.111.111"],
    #   whitelist: ["222.222.222.222"]
    # )
    # ```
    class Throttle
      include HTTP::Handler

      # Thread-safe request tracker structure
      private struct RequestTracker
        property expires : Int64
        property requests : Int32
        property block_expires : Int64?

        def initialize(@expires : Int64, @requests : Int32 = 0, @block_expires : Int64? = nil)
        end

        def blocked? : Bool
          !@block_expires.nil?
        end

        def block_expired?(current_time : Int64) : Bool
          if block_time = @block_expires
            block_time < current_time
          else
            false
          end
        end

        def watch_expired?(current_time : Int64) : Bool
          @expires <= current_time
        end

        def increment_requests : RequestTracker
          RequestTracker.new(@expires, @requests + 1, @block_expires)
        end

        def block(duration : Int32, current_time : Int64) : RequestTracker
          RequestTracker.new(@expires, @requests, current_time + duration)
        end
      end

      RETRY_AFTER    = "Retry-After"
      CONTENT_TYPE   = "Content-Type"
      CONTENT_LENGTH = "Content-Length"
      REMOTE_ADDR    = "REMOTE_ADDR"

      private getter log : ::Log = CONFIG.log,
        interval : Int32 = 5,
        duration : Int32 = 900,
        threshold : Int32 = 100,
        blacklist : Array(String) = [] of String,
        whitelist : Array(String) = [] of String

      @tracker : Hash(String, RequestTracker)
      @mutex : Mutex

      def initialize(@interval, @duration, @threshold, @blacklist, @whitelist)
        @tracker = Hash(String, RequestTracker).new
        @mutex = Mutex.new
      end

      def call(context : HTTP::Server::Context)
        remote = context.request.headers[REMOTE_ADDR]? || "unknown"

        return call_next(context) unless deflect?(remote)
        too_many_requests(context, remote)
      end

      private def deflect?(remote : String) : Bool
        return false if whitelisted?(remote)
        return true if blacklisted?(remote)

        @mutex.synchronize { watch(remote) }
      end

      private def too_many_requests(context, remote : String)
        retry_after = @mutex.synchronize do
          if tracker = @tracker[remote]?
            tracker.block_expires || 0
          else
            0
          end
        end

        context.response.headers[CONTENT_TYPE] = "text/plain"
        context.response.headers[CONTENT_LENGTH] = "0"
        context.response.headers[RETRY_AFTER] = "#{retry_after}"
        context.response.status_code = HTTP::Status::TOO_MANY_REQUESTS.value
        context.response.close
      end

      # All methods below must be called within @mutex.synchronize block
      private def watch(remote : String) : Bool
        current_time = Time.utc.to_unix
        tracker = get_or_create_tracker(remote, current_time)

        # Increment requests
        tracker = tracker.increment_requests
        @tracker[remote] = tracker

        # Check if watch period expired and not blocked
        if tracker.watch_expired?(current_time) && !tracker.blocked?
          @tracker.delete(remote)
          return false
        end

        # Check if block period expired
        if tracker.blocked? && tracker.block_expired?(current_time)
          @tracker.delete(remote)
          log.warn { "#{remote} released" }
          return false
        end

        # Check if threshold exceeded and should be blocked
        if !tracker.blocked? && tracker.requests > threshold
          @tracker[remote] = tracker.block(duration, current_time)
          log.warn { "#{remote} blocked" }
          return true
        end

        tracker.blocked?
      end

      private def get_or_create_tracker(remote : String, current_time : Int64) : RequestTracker
        @tracker[remote]? || RequestTracker.new(current_time + interval, 0)
      end

      private def blacklisted?(remote : String) : Bool
        blacklist.includes?(remote)
      end

      private def whitelisted?(remote : String) : Bool
        whitelist.includes?(remote)
      end

      # Reset tracker (useful for testing)
      def reset
        @mutex.synchronize do
          @tracker.clear
        end
      end

      # Get tracker stats (useful for monitoring)
      def stats
        @mutex.synchronize do
          {
            tracked_ips: @tracker.size,
            blocked_ips: @tracker.count { |_, tracker| tracker.blocked? },
          }
        end
      end
    end
  end
end

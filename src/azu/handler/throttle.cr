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
    # All five are required:
    #
    #   * **interval**   Seconds until the request counter is reset
    #   * **duration**   Seconds a remote address stays blocked
    #   * **threshold**  Number of requests allowed per interval
    #   * **blacklist**  Remote addresses refused at once
    #   * **whitelist**  Remote addresses never throttled
    #
    # `log:` is optional: without it, the log of the app serving the request. The others are optional too:
    #
    #   * **trusted_proxies**  Addresses and CIDR blocks of the reverse proxies in front of the app. Only a request
    #     whose connection comes from one of them has its `X-Forwarded-For` read, from the right, up to the first
    #     address that is not a trusted proxy: that is the client. Empty (the default): the connection's address.
    #   * **ipv6_prefix**  IPv6 clients are counted by their first N bits (64 by default), since one subscriber
    #     owns a whole /64.
    #   * **max_clients**  The most clients tracked at once (100 000 by default); see "Memory" below.
    #
    # ### Memory
    #
    # A tracker whose window and block have ended is dropped by a sweep that runs on a request, at most once a second
    # (no fiber). When more than `max_clients` are tracked the oldest ones that are not blocked go first.
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
        property expires : Time::Instant
        property requests : Int32
        property block_expires : Time::Instant?

        def initialize(@expires : Time::Instant, @requests : Int32 = 0, @block_expires : Time::Instant? = nil)
        end

        def blocked? : Bool
          !@block_expires.nil?
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

      # Throttle's own 429, the only error whose HTML page is cached: its text is fixed by `Retry-After`, so what
      # one client is shown is what another would be. An error a user raises (`RateLimitError`, or a subclass of it)
      # is never cached, as it carries text of its own; a subclass of Refusal is such an error too.
      class Refusal < Response::RateLimitError
        # A refused client keeps asking, so the page is rendered once a second for the same templates, `Retry-After`
        # and locale. The response carries the `error_id` the page shows, so refusals inside that second share one
        # id (nothing reports a Throttle refusal to `ERROR_REPORTER`, which would want an id per occurrence).
        # A custom `error.html` must be request independent: it is rendered for one request and served to others.
        # Development renders the debug page every time.
        def html(context : HTTP::Server::Context) : String
          return super if env.development? || self.class != Refusal

          page = RefusalPages.fetch(templates, retry_after, Helpers::I18n.locale) { {error_id, html} }
          @error_id = page.error_id
          context.response.headers["X-Error-ID"] = page.error_id
          page.html
        end

        private def generate_fingerprint : String
          return super unless self.class == Refusal

          @@refusal_fingerprint ||= super
        end

        # Named apart from RateLimitError's @@fingerprint: the class name is part of what is hashed.
        @@refusal_fingerprint : String?
      end

      module RefusalPages
        LIFETIME = 1.second
        MAX      = 128

        record Page, error_id : String, html : String, expires : Time::Instant

        @@pages = {} of {UInt64, Int32?, String} => Page
        @@lock = Mutex.new

        def self.fetch(templates : Templates, retry_after : Int32?, locale : String, & : -> {String, String}) : Page
          key = {templates.object_id, retry_after, locale}
          now = Clock.instant
          @@lock.synchronize do
            @@pages[key]?.try { |page| return page if page.expires > now }
          end

          error_id, html = yield
          page = Page.new(error_id, html, now + LIFETIME)
          @@lock.synchronize do
            @@pages.clear if @@pages.size >= MAX
            @@pages[key] = page
          end
          page
        end

        def self.size : Int32
          @@lock.synchronize { @@pages.size }
        end

        def self.clear : Nil
          @@lock.synchronize { @@pages.clear }
        end
      end

      # At most this many refusals are logged a second; the rest are counted and summarised.
      LOG_PER_SECOND = 10

      FORWARDED_FOR  = "X-Forwarded-For"
      RETRY_AFTER    = "Retry-After"
      CONTENT_TYPE   = "Content-Type"
      CONTENT_LENGTH = "Content-Length"
      UNKNOWN_CLIENT = "unknown"

      DEFAULT_MAX_CLIENTS = 100_000
      SWEEP_EVERY         = 1.second

      private getter interval : Int32 = 5,
        duration : Int32 = 900,
        threshold : Int32 = 100,
        blacklist : Array(String) = [] of String,
        whitelist : Array(String) = [] of String

      @log : ::Log?
      @log_mutex = Mutex.new
      @log_window = Clock.instant
      @logged = 0
      @suppressed = 0
      @tracker : Hash(String, RequestTracker)
      @mutex : Mutex
      @trusted : ClientAddress::Networks
      @ipv6_prefix : Int32
      @max_clients : Int32
      @next_sweep : Time::Instant
      @blocked_addresses : Set(String)
      @allowed_addresses : Set(String)

      # Without an explicit log, the log of the app serving the request (`Azu.current_config`).
      # *trusted_proxies* raises `ArgumentError` for an entry that is not an IP address or CIDR block.
      def initialize(@interval, @duration, @threshold, @blacklist, @whitelist, @log : ::Log? = nil,
                     trusted_proxies : Array(String) = [] of String, ipv6_prefix : Int32 = 64, max_clients : Int32 = DEFAULT_MAX_CLIENTS)
        raise ArgumentError.new("ipv6_prefix must be between 1 and 128") unless 1 <= ipv6_prefix <= 128
        raise ArgumentError.new("max_clients must be positive") unless max_clients > 0
        @trusted = ClientAddress::Networks.parse(trusted_proxies)
        @ipv6_prefix = ipv6_prefix
        @max_clients = max_clients
        @blocked_addresses = @blacklist.map { |entry| normalized(entry) }.to_set
        @allowed_addresses = @whitelist.map { |entry| normalized(entry) }.to_set
        @tracker = Hash(String, RequestTracker).new
        @mutex = Mutex.new
        @next_sweep = Clock.instant + SWEEP_EVERY
      end

      private def log : ::Log
        @log || Azu.current_config.log
      end

      def call(context : HTTP::Server::Context)
        client = client_address(context)

        return call_next(context) unless deflect?(client)
        too_many_requests(context, client.key)
      end

      # Who a request is from: the address, as it is compared with the black and white lists, and the key its
      # requests are counted under (the same for IPv4, the network for IPv6).
      private record Client, address : String, key : String

      # Clients are identified by the peer address of the connection. A header such as
      # REMOTE_ADDR is never set by the server and a client can send any value for it,
      # which would let it dodge the limit, borrow a whitelisted address or frame another one.
      # `X-Forwarded-For` is read only when the connection comes from a trusted proxy (see `ClientAddress.client`).
      private def client_address(context : HTTP::Server::Context) : Client
        case address = context.request.remote_address
        when Socket::IPAddress then identify(address, context.request.headers)
        when Nil               then Client.new(UNKNOWN_CLIENT, UNKNOWN_CLIENT)
        else                        Client.new(address.to_s, address.to_s)
        end
      end

      private def identify(peer : Socket::IPAddress, headers : HTTP::Headers) : Client
        return Client.new(peer.address, peer.address) unless parsed = ClientAddress.parse(peer.address)
        client = ClientAddress.client(parsed, headers.get?(FORWARDED_FOR), @trusted)
        Client.new(ClientAddress.to_s(client), ClientAddress.key(client, @ipv6_prefix))
      end

      private def deflect?(client : Client) : Bool
        return false if whitelisted?(client.address)
        return true if blacklisted?(client.address)

        @mutex.synchronize { watch(client.key) }
      end

      private def too_many_requests(context, remote : String)
        retry_after = @mutex.synchronize do
          if tracker = @tracker[remote]?
            if block_exp = tracker.block_expires
              remaining = block_exp - Clock.instant
              remaining.total_seconds.to_i64
            else
              0_i64
            end
          else
            0_i64
          end
        end

        error = Refusal.new(retry_after.to_i32)
        log_refusal(context.request, error)
        error.to_s(context)
        context.response.close
      end

      # A flood of refusals must not become a flood of log lines: LOG_PER_SECOND a second are written, and the next
      # window starts with one line saying how many were left out.
      private def log_refusal(request : HTTP::Request, error : Refusal) : Nil
        now = Clock.instant
        summary = 0
        write = @log_mutex.synchronize do
          if now - @log_window >= 1.second
            summary = @suppressed
            @log_window = now
            @logged = 0
            @suppressed = 0
          end
          if @logged < LOG_PER_SECOND
            @logged += 1
            true
          else
            @suppressed += 1
            false
          end
        end
        log.warn { "suppressed #{summary} similar refusals in the last second" } if summary > 0
        LogText.log_refusal(log, request, error, client: true) if write
      end

      # All methods below must be called within @mutex.synchronize block
      private def watch(remote : String) : Bool
        # Use monotonic time to prevent clock skew vulnerabilities
        # (e.g., NTP adjustments causing indefinite blocks)
        current_time = Clock.instant
        sweep(current_time)
        tracker = get_or_create_tracker(remote, current_time)
        make_room(remote)

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

      # Drops the trackers whose window and block have ended, at most once per SWEEP_EVERY, on a request.
      private def sweep(current_time : Time::Instant) : Nil
        return if current_time < @next_sweep
        @next_sweep = current_time + SWEEP_EVERY
        @tracker.reject! { |_, tracker| stale?(tracker, current_time) }
      end

      private def stale?(tracker : RequestTracker, current_time : Time::Instant) : Bool
        tracker.blocked? ? tracker.block_expired?(current_time) : tracker.watch_expired?(current_time)
      end

      # A new client does not grow the table past max_clients: the oldest trackers that are not blocked go first (the
      # table keeps the order clients were first seen in), then, only when every one is blocked, the oldest block.
      private def make_room(remote : String) : Nil
        return if @tracker.size < @max_clients || @tracker.has_key?(remote)
        excess = @tracker.size - @max_clients + 1
        oldest = @tracker.each_key.reject { |key| @tracker[key].blocked? }.first(excess).to_a
        oldest.concat(@tracker.each_key.reject { |key| oldest.includes?(key) }.first(excess - oldest.size).to_a) if oldest.size < excess
        oldest.each { |key| @tracker.delete(key) }
      end

      private def get_or_create_tracker(remote : String, current_time : Time::Instant) : RequestTracker
        @tracker[remote]? || RequestTracker.new(current_time + interval.seconds, 0)
      end

      private def blacklisted?(address : String) : Bool
        @blocked_addresses.includes?(address)
      end

      private def whitelisted?(address : String) : Bool
        @allowed_addresses.includes?(address)
      end

      # A list entry in the form a client address is compared in (`::ffff:1.2.3.4` is `1.2.3.4`); text that is not
      # an IP address stays as it was written.
      private def normalized(entry : String) : String
        ClientAddress.parse(entry).try { |address| ClientAddress.to_s(address) } || entry
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

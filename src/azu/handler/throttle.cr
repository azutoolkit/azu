require "./throttle/store"
require "./throttle/memory"
require "./throttle/redis"

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
    #   * **interval**   Seconds until the request counter is reset (5)
    #   * **duration**   Seconds a remote address stays blocked (900)
    #   * **threshold**  Number of requests allowed per interval (100)
    #   * **blacklist**  Remote addresses refused at once (none)
    #   * **whitelist**  Remote addresses never throttled (none)
    #
    # `log:` is optional: without it, the log of the app serving the request. The others are optional too:
    #
    #   * **trusted_proxies**  Addresses and CIDR blocks of the reverse proxies in front of the app. Only a request
    #     whose connection comes from one of them has its `X-Forwarded-For` read, from the right, up to the first
    #     address that is not a trusted proxy: that is the client. Empty (the default): the connection's address.
    #   * **ipv6_prefix**  IPv6 clients are counted by their first N bits (64 by default), since one subscriber
    #     owns a whole /64.
    #   * **store**  Where the counters live: `Store::Memory` (this process; the default) or `Store::Redis` (every
    #     instance of the app together). Without one, `THROTTLE_STORE=redis` selects Redis (`THROTTLE_REDIS_URL`,
    #     then `REDIS_URL`), else memory.
    #   * **max_clients**  The most clients the memory store tracks at once (100 000 by default); see "Memory" below.
    #
    # ### Memory
    #
    # The memory store drops a tracker whose window and block have ended by a sweep that runs on a request, at most
    # once a second (no fiber). When more than `max_clients` are tracked the oldest ones that are not blocked go first.
    #
    # ### Clients it cannot identify
    #
    # A request without an IP peer (a UNIX socket listener, a server bound to something that is not a socket) names
    # no client: it passes uncounted, with one warning for the process. Listen on TCP, with the proxy in
    # `trusted_proxies`, to throttle behind a socket.
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
      UNRESOLVED     = "!forwarded"

      DEFAULT_MAX_CLIENTS = 100_000

      private getter interval : Int32,
        duration : Int32,
        threshold : Int32,
        blacklist : Array(String),
        whitelist : Array(String)

      # The store the counters live in.
      getter store : Store

      @log : ::Log?
      @refusal_lines = LogBudget.new(LOG_PER_SECOND)
      @event_lines = LogBudget.new(LOG_PER_SECOND)
      @unidentified_warned = Atomic(Bool).new(false)
      @limits : Limits
      @trusted : ClientAddress::Networks
      @ipv6_prefix : Int32
      @blacklisted : ClientAddress::Networks
      @whitelisted : ClientAddress::Networks

      # Without an explicit log, the log of the app serving the request (`Azu.current_config`).
      # *trusted_proxies*, *blacklist* and *whitelist* take IP addresses and CIDR blocks and raise `ArgumentError` for
      # any other entry; *trusted_proxies* also refuses a block that is everything (`0.0.0.0/0`, `::/0`).
      # *max_clients* sizes the memory store built when no *store* is given.
      def initialize(@interval : Int32 = 5, @duration : Int32 = 900, @threshold : Int32 = 100,
                     @blacklist : Array(String) = [] of String, @whitelist : Array(String) = [] of String, @log : ::Log? = nil,
                     trusted_proxies : Array(String) = [] of String, ipv6_prefix : Int32 = 64, max_clients : Int32 = DEFAULT_MAX_CLIENTS,
                     store : Store? = nil)
        raise ArgumentError.new("ipv6_prefix must be between 1 and 128") unless 1 <= ipv6_prefix <= 128
        raise ArgumentError.new("max_clients must be positive") unless max_clients > 0
        raise ArgumentError.new("interval and duration must be positive, threshold not negative") if @interval <= 0 || @duration <= 0 || @threshold < 0
        @limits = Limits.new(@interval, @duration, @threshold)
        @trusted = ClientAddress::Networks.parse(trusted_proxies, "trusted_proxies", catch_all: false)
        @ipv6_prefix = ipv6_prefix
        @blacklisted = ClientAddress::Networks.parse(@blacklist, "blacklist")
        @whitelisted = ClientAddress::Networks.parse(@whitelist, "whitelist")
        @store = store || Store.from_env(max_clients)
      end

      private def log : ::Log
        @log || Azu.current_config.log
      end

      def call(context : HTTP::Server::Context)
        unless client = client_address(context)
          unidentified(context)
          return call_next(context)
        end

        verdict = deflect(client)
        return call_next(context) unless retry_after = verdict.retry_after
        too_many_requests(context, retry_after)
      end

      # Who a request is from: the address, as it is compared with the black and white lists, and the key its
      # requests are counted under (the same for IPv4, the network for IPv6).
      private record Client, address : String, key : String, ip : UInt128? = nil

      # Clients are identified by the peer address of the connection. A header such as
      # REMOTE_ADDR is never set by the server and a client can send any value for it,
      # which would let it dodge the limit, borrow a whitelisted address or frame another one.
      # `X-Forwarded-For` is read only when the connection comes from a trusted proxy (see `ClientAddress.client`).
      # Nil for a request without an IP peer (none, or a UNIX socket's): nothing identifies its client.
      private def client_address(context : HTTP::Server::Context) : Client?
        address = context.request.remote_address
        identify(address, context.request.headers) if address.is_a?(Socket::IPAddress)
      end

      # Every such request would share one bucket, so one visitor could lock every other out: they pass instead.
      private def unidentified(context : HTTP::Server::Context) : Nil
        return if @unidentified_warned.swap(true)
        peer = context.request.remote_address.try { |address| " (#{address.class.name.rpartition("::").last})" } || ""
        log.warn { "#{context.request.method} #{context.request.path}: the request has no IP peer address#{peer}, so Throttle cannot tell its client and lets such requests pass; listen on TCP (with the proxy in trusted_proxies) to count them" }
      end

      private def identify(peer : Socket::IPAddress, headers : HTTP::Headers) : Client
        return Client.new(peer.address, peer.address) unless parsed = ClientAddress.parse(peer.address)
        return Client.new(ClientAddress.to_s(parsed), ClientAddress.key(parsed, @ipv6_prefix), parsed) if @trusted.empty?

        if client = ClientAddress.client(parsed, headers.get?(FORWARDED_FOR), @trusted)
          Client.new(ClientAddress.to_s(client), ClientAddress.key(client, @ipv6_prefix), client)
        else
          # A trusted proxy sent a header that names no client: counted apart from the proxy's own requests (a health
          # check carries no header), so whoever can make a proxy forward garbage only throttles itself.
          # No `ip`: the lists are not consulted. Whitelisting the proxy must not exempt whoever makes it forward garbage.
          Client.new(ClientAddress.to_s(parsed), "#{ClientAddress.key(parsed, @ipv6_prefix)}#{UNRESOLVED}")
        end
      end

      # A whitelisted client is never counted; a blacklisted one is refused for `duration` without being counted.
      private def deflect(client : Client) : Verdict
        if ip = client.ip
          return Verdict.new if @whitelisted.includes?(ip)
          return Verdict.new(duration) if @blacklisted.includes?(ip)
        end

        verdict = @store.hit(client.key, @limits)
        case verdict.event
        in Verdict::Event::Blocked  then log_event("#{client.key} blocked")
        in Verdict::Event::Released then log_event("#{client.key} released")
        in Nil                      then nil
        end
        verdict
      end

      private def too_many_requests(context, retry_after : Int32)
        error = Refusal.new(retry_after)
        log_refusal(context.request, error)
        error.to_s(context)
        context.response.close
      end

      # A flood of refusals must not become a flood of log lines: LOG_PER_SECOND a second are written, and the next
      # window starts with one line saying how many were left out.
      private def log_refusal(request : HTTP::Request, error : Refusal) : Nil
        write, summary = @refusal_lines.take
        log.warn { "suppressed #{summary} similar refusals in the last second" } if summary > 0
        LogText.log_refusal(log, request, error, client: true) if write
      end

      # Blocks and releases are bounded the same way (a flood of fresh addresses blocks one each), apart from refusals.
      private def log_event(message : String) : Nil
        write, summary = @event_lines.take
        log.warn { "suppressed #{summary} similar block and release lines in the last second" } if summary > 0
        log.warn { message } if write
      end

      # Forgets every client (`Store#reset`): for specs and operators.
      def reset : Nil
        @store.reset
      end

      # Clients tracked and blocked (`Store#stats`; zeros for the Redis store).
      def stats : NamedTuple(tracked_ips: Int32, blocked_ips: Int32)
        @store.stats
      end
    end
  end
end

require "http/web_socket"
require "./pub_sub"
require "./channel/*"

module Azu
  # A channel encapsulates a logical unit of work similar to an Endpoint.
  #
  # Channels manage WebSocket connections, handling multiple instances where a single client
  # may have multiple WebSocket connections open to the application.
  #
  # To set up a WebSocket route in your routing service:
  #
  # ```
  # ExampleApp.router do
  #   ws "/hi", ExampleApp::ExampleChannel
  # end
  # ```
  #
  # ## Security
  #
  # The `Origin` header of the upgrade request must be same-origin or listed in
  # `Azu::CONFIG.websocket.allowed_origins` (`"*"` allows any), which blocks cross-site
  # WebSocket hijacking from browsers. Messages larger than
  # `Azu::CONFIG.websocket.max_message_size` close the connection.
  #
  # ## Pings and Pongs: The Heartbeat of WebSockets
  #
  # After the handshake, either the client or the server can send a ping to the other party.
  # Upon receiving a ping, the recipient must promptly send back a pong. The server pings
  # every `Azu::CONFIG.websocket.ping_interval` so dead peers are detected.
  #
  # ## Broadcasting
  #
  # `subscribe` joins a topic of `Azu::PubSub`; every `broadcast` to it reaches `on_broadcast`
  # (which forwards the payload to the socket by default). Subscriptions end with the connection.
  abstract class Channel
    include HTTP::Handler

    getter! socket : HTTP::WebSocket
    # The upgrade request, available from `on_connect` on.
    getter! context : HTTP::Server::Context

    def initialize(@socket : HTTP::WebSocket)
      @send_mutex = Mutex.new
      @subscriptions = {} of String => PubSub::Subscription
      @subscriptions_mutex = Mutex.new
      @subscribing = {} of String => PubSub::Reservation
      @closed = ::Channel(Nil).new
      @torn_down = false
      @last_frame_at = Atomic(Int64).new(Clock.coarse_nanoseconds)
    end

    # True once the connection was torn down (closed by the peer, by `close`, or by the idle timeout).
    getter? torn_down : Bool

    # The connection's IO, set by the upgrader: what the idle timeout closes when the peer does not answer the close
    # frame, so a hung peer does not keep a socket and a fiber until TCP gives up.
    setter transport : IO?

    # Query string of the upgrade request.
    def params : HTTP::Params
      context.request.query_params
    end

    # Headers of the upgrade request (cookies, `Origin`, ...).
    def headers : HTTP::Headers
      context.request.headers
    end

    # Registers a WebSocket route
    def self.ws(path : Router::Path)
      CONFIG.router.ws(path, self)
    end

    # Origins accepted besides the same origin; `"*"` accepts any. Override per channel class if needed.
    def self.allowed_origins : Array(String)
      Azu.current_config.websocket.allowed_origins
    end

    def self.max_message_size : Int32
      Azu.current_config.websocket.max_message_size
    end

    # Interval between server pings; `nil` disables them.
    def self.ping_interval : Time::Span?
      Azu.current_config.websocket.ping_interval
    end

    # The most topics one connection may subscribe to (`websocket.max_subscriptions`).
    def self.max_subscriptions : Int32
      Azu.current_config.websocket.max_subscriptions
    end

    # How long a connection may send nothing before it is closed (`websocket.idle_timeout`); nil never closes it.
    def self.idle_timeout : Time::Span?
      Azu.current_config.websocket.idle_timeout
    end

    # Browsers always send `Origin` on WebSocket handshakes, so a missing header can only come
    # from a non-browser client and is accepted. The request's own origin is its `Host` under the scheme it was
    # served with when that is known (this app's TLS, else a proxy's `X-Forwarded-Proto`): a page on
    # `http://example.com` may not open a socket to `https://example.com`. Without either hint, either scheme passes.
    def self.origin_allowed?(request : HTTP::Request) : Bool
      return true unless origin = request.headers["Origin"]?
      return true if allowed_origins.includes?("*") || allowed_origins.includes?(origin)
      return false unless host = request.headers["Host"]?

      scheme, separator, origin_host = origin.partition("://")
      return false if separator.empty? || origin_host.compare(host, case_insensitive: true) != 0
      expected = expected_scheme(request)
      expected.nil? || scheme.compare(expected, case_insensitive: true) == 0
    end

    # The scheme the upgrade request was served with, when it can be told.
    private def self.expected_scheme(request : HTTP::Request) : String?
      return "https" if Azu.current_config.tls?
      request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip.downcase.presence)
    end

    # Raised by `subscribe` for the topic past `max_subscriptions`: a client that names its own topics cannot grow the
    # process's tables without bound.
    class TooManySubscriptions < Exception
      def initialize(limit : Int32)
        super("a connection may subscribe to at most #{limit} topics")
      end
    end

    # Invoked when a connection is established
    abstract def on_connect

    # Invoked when a text message is received
    abstract def on_message(message : String)

    # Invoked when a binary message is received
    abstract def on_binary(binary : Bytes)

    # Invoked when a ping frame is received
    abstract def on_ping(message : String)

    # Invoked when a pong frame is received
    abstract def on_pong(message : String)

    # Invoked when the connection is closed
    abstract def on_close(code : HTTP::WebSocket::CloseCode?, message : String?)

    # Invoked for each message broadcast to a subscribed topic.
    def on_broadcast(message : PubSub::Message) : Nil
      send(message.payload)
    end

    # Handles the incoming WebSocket HTTP request
    def call(context : HTTP::Server::Context)
      @context = context
      on_connect

      socket.on_message { |message| seen; on_message(message) }
      socket.on_binary { |binary| seen; on_binary(binary) }
      socket.on_ping { |message| seen; on_ping(message) }
      socket.on_pong { |message| seen; on_pong(message) }
      socket.on_close do |code, message|
        teardown
        on_close(code, message)
      end
      start_heartbeat
    end

    # Writes a text frame. Safe to call from any fiber.
    def send(message : String) : Nil
      @send_mutex.synchronize { socket.send(message) }
    end

    # Writes a binary frame. Safe to call from any fiber.
    def send(bytes : Bytes) : Nil
      @send_mutex.synchronize { socket.send(bytes) }
    end

    # Sends a close frame. Safe to call from any fiber; a socket that is already gone is ignored.
    def close(code : HTTP::WebSocket::CloseCode = HTTP::WebSocket::CloseCode::NormalClosure, message : String? = nil) : Nil
      @send_mutex.synchronize { socket.close(code, message) }
    rescue IO::Error
    end

    # Raises `ArgumentError` for the topics `Azu::Presence` owns (`PubSub::RESERVED_PREFIX`).
    def subscribe(topic : String) : Nil
      reject_reserved(topic)
      subscribe_topic(topic)
    end

    # A backend may wait before it returns (a Redis backend waits for Redis to confirm the first subscription), so
    # the topic is reserved under the lock and subscribed outside it: the lock is never held across the wait. A
    # second caller for a topic being subscribed waits for the first to finish (so a broadcast it makes right after
    # `subscribe` is not lost) and then follows its outcome: an unsubscribe in between leaves the topic
    # unsubscribed, a failure is raised again at once (a later call tries anew), success or teardown needs nothing.
    protected def subscribe_topic(topic : String) : Nil
      loop do
        reservation, mine = @subscriptions_mutex.synchronize do
          return if @torn_down || @subscriptions.has_key?(topic)
          limit = self.class.max_subscriptions
          # A topic being moved from @subscribing to @subscriptions is in both for a moment: counted once
          held = @subscriptions.size + @subscribing.count { |pending, _| !@subscriptions.has_key?(pending) }
          raise TooManySubscriptions.new(limit) if held >= limit && !@subscribing.has_key?(topic)
          if pending = @subscribing[topic]?
            {pending, false}
          else
            {(@subscribing[topic] = PubSub::Reservation.new), true}
          end
        end
        return subscribe_reserved(topic, reservation) if mine
        return if reservation.owned_by_caller?
        reservation.wait
        return if reservation.cancelled?
        reservation.error.try { |error| raise error }
      end
    end

    private def subscribe_reserved(topic : String, reservation : PubSub::Reservation) : Nil
      subscription = PubSub.subscribe(topic) { |message| deliver(message) }
      kept = @subscriptions_mutex.synchronize do
        next false if reservation.cancelled? || @torn_down
        @subscriptions[topic] = subscription
        true
      end
      subscription.cancel unless kept
    rescue ex
      reservation.fail(ex)
      raise ex
    ensure
      @subscriptions_mutex.synchronize { @subscribing.delete(topic) if @subscribing[topic]?.same?(reservation) }
      reservation.finish
    end

    def unsubscribe(topic : String) : Nil
      subscription = @subscriptions_mutex.synchronize do
        # The subscribe in flight must not store itself, and a later subscribe must start a reservation of its own
        # rather than wait for (and follow) this cancelled one.
        @subscribing.delete(topic).try(&.cancel)
        @subscriptions.delete(topic)
      end
      subscription.try(&.cancel)
    end

    # Raises `ArgumentError` for the topics `Azu::Presence` owns, so a client-chosen topic cannot forge a diff.
    def broadcast(topic : String, message : String) : Nil
      reject_reserved(topic)
      PubSub.broadcast(topic, message)
    end

    private def reject_reserved(topic : String) : Nil
      raise ArgumentError.new("topic #{topic.inspect} is reserved for Azu::Presence") if PubSub.reserved?(topic)
    end

    private def deliver(message : PubSub::Message) : Nil
      on_broadcast(message)
    rescue IO::Error
      # The peer is gone; the close callback releases the subscription.
    end

    # Stops the heartbeat and cancels every subscription. Idempotent: it runs from the close
    # callback and, for connections that end abnormally (e.g. `on_message` raised), from the
    # upgrader's `ensure`.
    def teardown : Nil
      subscriptions = @subscriptions_mutex.synchronize do
        return if @torn_down
        @torn_down = true
        @subscriptions.values.tap { @subscriptions.clear }
      end
      @closed.close
      subscriptions.each(&.cancel)
    end

    private def start_heartbeat : Nil
      return unless interval = self.class.ping_interval
      Azu.spawn_scoped("azu-ws-heartbeat") { ping_until_closed(interval) }
    end

    # How long the peer gets to answer an idle close before its connection is closed underneath it.
    CLOSE_GRACE = 1.second

    private def ping_until_closed(interval : Time::Span) : Nil
      loop do
        select
        when @closed.receive?
          break
        when timeout(interval)
          break if idle_too_long(interval)
          @send_mutex.synchronize { socket.ping }
        end
      end
    rescue IO::Error
      # The socket closed between two pings.
    end

    # Notes that the peer sent a frame.
    private def seen : Nil
      @last_frame_at.set(Clock.coarse_nanoseconds)
    end

    # Closes a connection that sent nothing for `idle_timeout` (never less than two pings, so a healthy silent peer
    # has been pinged before it is given up): the peer is gone or hung, and its subscriptions would otherwise be held
    # until the TCP stack gives up. The close frame is sent and the subscriptions released at once; the connection
    # itself is closed after `CLOSE_GRACE` unless the peer answered. `on_close` runs when the peer's answer (or the
    # closed connection) ends the socket's loop. True when the connection was given up.
    private def idle_too_long(interval : Time::Span) : Bool
      return false unless limit = self.class.idle_timeout
      limit = {limit, interval * 2}.max
      return false if Clock.coarse_nanoseconds - @last_frame_at.get < limit.total_nanoseconds

      # Released and scheduled before the close frame is written: a peer whose window is full would block that write
      teardown
      if transport = @transport
        Azu.spawn_scoped("azu-ws-idle-close") do
          sleep CLOSE_GRACE
          transport.close rescue nil
        end
      end
      close(HTTP::WebSocket::CloseCode::GoingAway, "idle for #{limit.total_seconds.to_i} seconds")
      true
    end
  end
end

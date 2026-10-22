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
      @closed = ::Channel(Nil).new
      @torn_down = false
    end

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

    # Browsers always send `Origin` on WebSocket handshakes, so a missing header can only come
    # from a non-browser client and is accepted.
    def self.origin_allowed?(request : HTTP::Request) : Bool
      return true unless origin = request.headers["Origin"]?
      return true if allowed_origins.includes?("*") || allowed_origins.includes?(origin)
      host = request.headers["Host"]?
      !host.nil? && origin.sub(%r{\A[a-z][a-z0-9+.\-]*://}i, "").compare(host, case_insensitive: true) == 0
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

      socket.on_message { |message| on_message(message) }
      socket.on_binary { |binary| on_binary(binary) }
      socket.on_ping { |message| on_ping(message) }
      socket.on_pong { |message| on_pong(message) }
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

    # Sends a close frame. Safe to call from any fiber; a socket that is already gone is ignored.
    def close(code : HTTP::WebSocket::CloseCode = HTTP::WebSocket::CloseCode::NormalClosure, message : String? = nil) : Nil
      @send_mutex.synchronize { socket.close(code, message) }
    rescue IO::Error
    end

    def subscribe(topic : String) : Nil
      @subscriptions_mutex.synchronize do
        @subscriptions[topic] ||= PubSub.subscribe(topic) { |message| deliver(message) }
      end
    end

    def unsubscribe(topic : String) : Nil
      subscription = @subscriptions_mutex.synchronize { @subscriptions.delete(topic) }
      subscription.try(&.cancel)
    end

    def broadcast(topic : String, message : String) : Nil
      PubSub.broadcast(topic, message)
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
      spawn(name: "azu-ws-heartbeat") { ping_until_closed(interval) }
    end

    private def ping_until_closed(interval : Time::Span) : Nil
      loop do
        select
        when @closed.receive?
          break
        when timeout(interval)
          @send_mutex.synchronize { socket.ping }
        end
      end
    rescue IO::Error
      # The socket closed between two pings.
    end
  end
end

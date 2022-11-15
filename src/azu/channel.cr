require "http/web_socket"

module Azu
  #
  # A channel encapsulates a logical unit of work similar to an Endpoint.
  #
  # Channels are used for websocket connections that can handle multiple connections
  # instances. A single client may have multiple WebSockets connections open to the application.
  #
  # Each channel can in turn broadcast to multiple connected clients
  #
  # You must setup a websocket route in your routing service
  #
  # ```
  # ExampleApp.router do
  #   ws "/hi", ExampleApp::ExampleChannel
  # end
  # ```
  #
  # ## Pings and Pongs: The Heartbeat of WebSockets
  #
  # At any point after the handshake, either the client or the server can choose
  # to send a ping to the other party. When the ping is received, the recipient
  # must send back a pong as soon as possible. You can use this to make sure
  # that the client is still connected, for example.
  #
  abstract class Channel
    getter! socket : HTTP::WebSocket
    @context : HTTP::Server::Context? = nil

    def initialize(@socket : HTTP::WebSocket)
    end

    # Registers a websocket route
    def self.ws(path : Router::Path)
      CONFIG.router.ws(path, self)
    end

    # On Connect event handler
    # Invoked when incoming socket connection connects to the endpoint
    abstract def on_connect

    # Invoked when the channel receives a message
    abstract def on_message(message)

    # Invoked when the channel receives a binary message
    abstract def on_binary(binary)

    # Invoked when the client has requested a ping message
    #
    # Pings have an opcode of 0x9
    abstract def on_ping(message)

    # Invoked when the client has requested a pong message
    #
    # Pongs have an opcode of 0xA
    abstract def on_pong(message)

    # Invoked when the channel process is about to exit.
    abstract def on_close(code : HTTP::WebSocket::CloseCode | Int? = nil, message = nil)

    # Handler to execute the incomming websocket http request
    def call(context : HTTP::Server::Context)
      @context = context

      on_connect

      socket.on_message do |message|
        on_message message
      end

      socket.on_binary do |binary|
        on_binary binary
      end

      socket.on_ping do |message|
        on_ping message
      end

      socket.on_pong do |message|
        on_pong message
      end

      socket.on_close do |code, message|
        on_close(code, message)
      end
    end
  end
end

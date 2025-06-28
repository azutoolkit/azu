require "http/web_socket"

module Azu
  # A channel encapsulates a logical unit of work similar to an Endpoint.
  #
  # Channels manage WebSocket connections, handling multiple instances where a single client
  # may have multiple WebSocket connections open to the application.
  #
  # Each channel can broadcast to multiple connected clients.
  #
  # To set up a WebSocket route in your routing service:
  #
  # ```
  # ExampleApp.router do
  #   ws "/hi", ExampleApp::ExampleChannel
  # end
  # ```
  #
  # ## Pings and Pongs: The Heartbeat of WebSockets
  #
  # After the handshake, either the client or the server can send a ping to the other party.
  # Upon receiving a ping, the recipient must promptly send back a pong. This mechanism ensures
  # that the client remains connected.
  abstract class Channel
    include HTTP::Handler

    getter! socket : HTTP::WebSocket

    def initialize(@socket : HTTP::WebSocket)
    end

    # Registers a WebSocket route
    def self.ws(path : Router::Path)
      CONFIG.router.ws(path, self)
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

    # Handles the incoming WebSocket HTTP request
    def call(context : HTTP::Server::Context)
      on_connect

      socket.on_message { |message| on_message(message) }
      socket.on_binary { |binary| on_binary(binary) }
      socket.on_ping { |message| on_ping(message) }
      socket.on_pong { |message| on_pong(message) }
      socket.on_close { |code, message| on_close(code, message) }
    end
  end
end

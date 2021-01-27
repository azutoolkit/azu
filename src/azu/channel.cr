require "http/web_socket"

module Azu
  # A channel encapsulates a logical unit of work similar to an Endpoint.
  #
  # Channels are used for websocket connections that can handle multiple connections
  # instances. A single client may have multiple WebSockets connections open to the application.
  #
  # Each channel can in turn broadcast to multiple connected clients
  #
  # You must setup a websocket route in your routing service
  #
  # ```crystal
  # ExampleApp.router do
  #   ws "/hi", ExampleApp::ExampleChannel
  # end
  # ```
  abstract class Channel
    getter! socket : HTTP::WebSocket
    @context = uninitialized HTTP::Server::Context

    def initialize(@socket : HTTP::WebSocket)
    end

    abstract def on_connect
    abstract def on_message(message)
    abstract def on_binary(binary)
    abstract def on_ping(message)
    abstract def on_pong(message)
    abstract def on_close(code : CloseCode | Int? = nil, message = nil)

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

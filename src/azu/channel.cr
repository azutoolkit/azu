require "http/web_socket"
require "./helpers"

module Azu
  abstract class Channel
    include Helpers
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

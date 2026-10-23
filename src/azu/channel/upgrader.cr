require "http/server"
require "./bounded_protocol"

module Azu
  abstract class Channel
    # Performs the WebSocket handshake for a `Channel` class: validates the request and its
    # `Origin`, then hands the upgraded socket to a new channel instance.
    class Upgrader
      include HTTP::Handler

      getter channel : Channel.class

      def initialize(@channel : Channel.class)
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        return call_next(context) unless upgrade_request?(request)
        return context.response.respond_with_status(:bad_request) unless valid_handshake?(request)
        return unsupported_version(context) unless request.headers["Sec-WebSocket-Version"]? == HTTP::WebSocket::Protocol::VERSION
        return reject_origin(context) unless @channel.origin_allowed?(request)

        accept(context)
      end

      private def accept(context : HTTP::Server::Context) : Nil
        response = context.response
        response.status = :switching_protocols
        response.headers["Upgrade"] = "websocket"
        response.headers["Connection"] = "Upgrade"
        response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(context.request.headers["Sec-WebSocket-Key"])
        # The upgrade block runs after the handler chain has returned, outside the app's scope.
        config = Azu.current_config
        app = Azu.current_app
        response.upgrade do |io|
          Azu.with_config(config) do
            socket = HTTP::WebSocket.new(BoundedProtocol.new(io, @channel.max_message_size))
            run(app, @channel.new(socket), context, socket)
          end
        end
      end

      # The app counts the socket and closes it with 1001 when it shuts down; a socket accepted
      # after that is told to go away without `on_connect` running.
      private def run(app : App?, channel : Channel, context : HTTP::Server::Context, socket : HTTP::WebSocket) : Nil
        return serve(channel, context, socket) unless app
        return if app.track_socket(channel) { serve(channel, context, socket) }

        channel.close(HTTP::WebSocket::CloseCode::GoingAway, "server shutting down")
        socket.run
      end

      private def serve(channel : Channel, context : HTTP::Server::Context, socket : HTTP::WebSocket) : Nil
        channel.call(context)
        socket.run
      ensure
        # `on_close` never fires when a handler raises out of `run`.
        channel.teardown
      end

      private def upgrade_request?(request : HTTP::Request) : Bool
        upgrade = request.headers["Upgrade"]?
        !upgrade.nil? &&
          upgrade.compare("websocket", case_insensitive: true) == 0 &&
          request.headers.includes_word?("Connection", "Upgrade")
      end

      private def valid_handshake?(request : HTTP::Request) : Bool
        request.method == "GET" &&
          request.version == "HTTP/1.1" &&
          request.headers.has_key?("Host") &&
          request.headers.has_key?("Sec-WebSocket-Key")
      end

      private def reject_origin(context : HTTP::Server::Context) : Nil
        Log.for("Azu::Channel").warn { "Rejected WebSocket upgrade from origin #{context.request.headers["Origin"]?}" }
        context.response.respond_with_status(:forbidden)
      end

      private def unsupported_version(context : HTTP::Server::Context) : Nil
        context.response.status = :upgrade_required
        context.response.headers["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
      end
    end
  end
end

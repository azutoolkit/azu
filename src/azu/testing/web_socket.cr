require "http/web_socket"

module Azu
  module Testing
    # A WebSocket connection to a channel of the app, in process. The handshake goes through the app's
    # real handler chain and router; the frames travel over a pair of pipes, so nothing listens on a port.
    class WebSocket
      class Timeout < Exception
      end

      # The handshake was refused (no route, bad origin, a handler said no); carries what the server answered.
      class Rejected < Exception
        getter response : Response

        def initialize(@response : Response)
          super("WebSocket handshake refused with #{response.status_code}")
        end
      end

      getter close_code : HTTP::WebSocket::CloseCode? = nil

      def initialize(client_io : IO, server_done : ::Channel(Nil))
        @messages = ::Channel(String).new(1024)
        @server_done = server_done
        @io = client_io
        @socket = HTTP::WebSocket.new(HTTP::WebSocket::Protocol.new(client_io, masked: true))
        @socket.on_message { |message| @messages.send(message) }
        @socket.on_close do |code, _|
          @close_code = code
          @messages.close
        end
        spawn(name: "azu-testing-ws-client") { run }
      end

      def send(message : String) : Nil
        @socket.send(message)
      end

      # The next text frame; nil when the server closed the socket or *timeout* passed.
      def receive?(timeout : Time::Span = 2.seconds) : String?
        select
        when message = @messages.receive?
          message
        when timeout(timeout)
          nil
        end
      end

      def receive(timeout : Time::Span = 2.seconds) : String
        receive?(timeout) || raise Timeout.new("no WebSocket message within #{timeout}")
      end

      def closed? : Bool
        @messages.closed?
      end

      # Sends a close frame and waits (up to *timeout*) until the channel's `on_close` has run.
      def close(code : HTTP::WebSocket::CloseCode = HTTP::WebSocket::CloseCode::NormalClosure, timeout : Time::Span = 2.seconds) : Nil
        @socket.close(code) unless @socket.closed?
        select
        when @server_done.receive?
        when timeout(timeout)
        end
        @io.close unless @io.closed?
      rescue IO::Error
      end

      private def run : Nil
        @socket.run
      rescue IO::Error
      ensure
        @messages.close unless @messages.closed?
      end
    end

    # Two pipes crossed into one duplex stream per side.
    class Duplex < IO
      def self.pair : {Duplex, Duplex}
        to_server_r, to_server_w = IO.pipe
        to_client_r, to_client_w = IO.pipe
        {new(to_client_r, to_server_w), new(to_server_r, to_client_w)}
      end

      def initialize(@reader : IO::FileDescriptor, @writer : IO::FileDescriptor)
      end

      def read(slice : Bytes) : Int32
        @reader.read(slice)
      end

      def write(slice : Bytes) : Nil
        @writer.write(slice)
      end

      def flush : Nil
        @writer.flush
      end

      def close : Nil
        @reader.close
        @writer.close
      end

      def closed? : Bool
        @reader.closed? && @writer.closed?
      end
    end
  end
end

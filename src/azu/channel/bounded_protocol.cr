require "http/web_socket"

module Azu
  abstract class Channel
    # WebSocket protocol that refuses messages above a size limit while they are still being
    # read, so a hostile peer cannot make the server buffer an unbounded message.
    class BoundedProtocol < HTTP::WebSocket::Protocol
      class MessageTooBig < IO::Error
      end

      def initialize(io : IO, @max_size : Int32)
        super(io, sync_close: false)
        @received = 0
      end

      def receive(buffer : Bytes) : PacketInfo
        info = super
        return info if info.opcode.close? || info.opcode.ping? || info.opcode.pong?

        @received += info.size
        reject_oversized if @received > @max_size
        @received = 0 if info.final
        info
      end

      private def reject_oversized : NoReturn
        close(HTTP::WebSocket::CloseCode::MessageTooBig, "message too big")
        raise MessageTooBig.new("WebSocket message exceeds #{@max_size} bytes")
      end
    end
  end
end

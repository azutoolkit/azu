require "http/server/handler"
require "compress/gzip"
require "compress/zlib"

module Azu
  module Handler
    # Compresses responses with gzip or deflate when the client accepts it: the standard library's
    # `HTTP::CompressHandler`, except that an event stream (`text/event-stream`) is left alone (compression
    # buffers, so the client would see events late or in batches) and that every response it decides on carries
    # `Vary: Accept-Encoding`.
    #
    # A compressed page that mixes a secret (a CSRF token, a session id) with text an attacker chooses is open to
    # BREACH: the size of the body leaks the secret byte by byte. Azu's CSRF tokens are random per page (the signed
    # token changes with every issue), which is the usual mitigation; leave the handler out for pages where it is not enough.
    class Compression < HTTP::CompressHandler
      def call(context : HTTP::Server::Context) : Nil
        context.response.output = Output.new(context.response.output, context)
        call_next(context)
      end

      private class Output < IO
        def initialize(@io : IO, @context : HTTP::Server::Context)
          @checked = false
        end

        def read(slice : Bytes)
          raise NotImplementedError.new("read")
        end

        def write(slice : Bytes) : Nil
          check_output unless @checked
          @io.write(slice)
        end

        # A flush before the first write may have put the headers on the wire: the decision is made.
        def flush
          @checked = true
          @io.flush
        end

        def close
          @io.close
        end

        private def check_output : Nil
          @checked = true
          response = @context.response
          return if response.headers.has_key?("Content-Encoding") || event_stream?

          # Compressed or not, the body depends on what the client accepts: a cache must not serve one client's to another
          Vary.add(response.headers, "Accept-Encoding")
          accepted = @context.request.headers
          if accepted.includes_word?("Accept-Encoding", "gzip")
            compress("gzip") { |io| Compress::Gzip::Writer.new(io, sync_close: true) }
          elsif accepted.includes_word?("Accept-Encoding", "deflate")
            compress("deflate") { |io| Compress::Zlib::Writer.new(io, sync_close: true) }
          end
        end

        private def event_stream? : Bool
          @context.response.headers["Content-Type"]?.try(&.starts_with?("text/event-stream")) || false
        end

        private def compress(encoding : String, & : IO -> IO) : Nil
          @context.response.headers["Content-Encoding"] = encoding
          @context.response.headers.delete("Content-Length")
          @io = yield @io
        end
      end
    end
  end
end

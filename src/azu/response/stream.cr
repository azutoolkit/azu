module Azu::Response
  # What the streaming responses (`Stream`, `EventStream`) have in common: the headers that keep a
  # proxy or the client from buffering, no body for HEAD, and an `on_close` that runs once the
  # response is over, whether it finished, the client went away or the app is shutting down.
  module Streaming
    include Azu::Response

    @on_close : (->)? = nil

    abstract def content_type : String

    # Writes the body to the connection; it returns when the stream is over.
    abstract def stream(context : HTTP::Server::Context) : Nil

    # Runs the block when the response is over (and the connection is released).
    def on_close(&block : ->) : self
      @on_close = block
      self
    end

    def render
    end

    def write_to(context : HTTP::Server::Context) : Nil
      response = context.response
      response.content_type = content_type
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"

      # A HEAD gets the headers of the GET, which is chunked: no Content-Length, and no body
      if context.request.method == "HEAD" && context.request.version != "HTTP/1.0"
        response.headers["Transfer-Encoding"] = "chunked"
      end
      begin
        stream(context) unless context.request.method == "HEAD"
      rescue IO::Error | HTTP::Server::ClientError
        # The client closed the connection; there is nobody left to answer.
      rescue ex
        # Once the headers are out nothing can answer with an error page: log it and end the body.
        raise ex unless response.@wrote_headers
        Azu.current_config.log.error(exception: ex) { "#{self.class} failed while streaming" }
      ensure
        @on_close.try(&.call)
      end
    end
  end

  # A body written in pieces while the handler runs, sent with chunked transfer encoding and flushed
  # after every write. The block gets a `Sink` to write to; a client that goes away makes the next write
  # raise, which ends the block and runs `on_close`.
  #
  # ```
  # def call : Azu::Response::Stream
  #   Azu::Response::Stream.new("text/csv") do |sink|
  #     sink << "id,name\n"
  #     rows.each { |row| sink << row.id << ',' << row.name << '\n' }
  #   end
  # end
  # ```
  #
  # A graceful shutdown waits for the block to return (`shutdown_timeout`): a long running one checks
  # `Azu.shutting_down?` and stops. For a stream of events that ends by itself, use `EventStream`.
  class Stream
    include Streaming

    getter content_type : String

    def initialize(@content_type : String = "application/octet-stream", &@body : Sink ->)
    end

    def stream(context : HTTP::Server::Context) : Nil
      @body.call(Sink.new(context.response))
    end

    # The writing end: every write is flushed to the client. `open?` turns false once a write failed.
    class Sink < IO
      getter? open = true

      def initialize(@io : IO)
      end

      def read(slice : Bytes) : NoReturn
        raise IO::Error.new("A stream can only be written to")
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("The client closed the connection") unless @open
        @io.write(slice)
        @io.flush
      rescue ex : IO::Error | HTTP::Server::ClientError
        @open = false
        raise ex
      end
    end
  end
end

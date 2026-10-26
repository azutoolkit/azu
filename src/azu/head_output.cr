module Azu
  # The response output of a HEAD request: it counts what the endpoint writes and sends none of it, so a HEAD
  # answers with the headers its GET would send and no body (RFC 9110 9.3.2). `HTTP::Server::Response` writes
  # whatever it is given, whatever the method, and a body after a HEAD answer is read by the client as the start
  # of the next response on the connection.
  #
  # `App` wraps the output of every HEAD request before its first handler runs, and `Router#process` does the
  # same for a server built on the router alone.
  class HeadOutput < IO
    getter count : Int64 = 0

    def initialize(@response : HTTP::Server::Response, @inner : IO)
    end

    # Wraps the output of `context` when it answers a HEAD request; does nothing for any other method, or when
    # it is already wrapped.
    def self.wrap(context : HTTP::Server::Context) : Nil
      return unless context.request.method == "HEAD"
      response = context.response
      return if response.output.is_a?(HeadOutput)
      response.output = new(response, response.output)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("Can't read from HTTP::Server::Response")
    end

    def write(slice : Bytes) : Nil
      @count += slice.size
    end

    # Nothing to flush: the headers go out when the response closes, with the length of what was written.
    def flush : Nil
    end

    def closed? : Bool
      @inner.closed?
    end

    # Sends the headers, with the `Content-Length` the GET would carry unless one was set, the body is chunked,
    # or the status has no body (204, 304, 1xx).
    def close : Nil
      return if closed?
      response = @response
      status = response.status
      unless response.@wrote_headers || response.headers.has_key?("Content-Length") ||
             response.headers.has_key?("Transfer-Encoding") ||
             status.not_modified? || status.no_content? || status.informational?
        response.content_length = @count
      end
      @inner.close
    end
  end
end

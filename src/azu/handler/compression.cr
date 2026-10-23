require "http/server/handler"

module Azu
  module Handler
    # Compresses responses with gzip or deflate when the client accepts it. It is the standard
    # library's `HTTP::CompressHandler` under the name the other handlers use.
    class Compression < HTTP::CompressHandler
    end
  end
end

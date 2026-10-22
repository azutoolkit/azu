require "http/headers"

module Azu
  module Spark
    # What a component may know about the WebSocket it lives on: an opaque connection id, the peer
    # address and the headers of the upgrade request (cookies, `User-Agent`, ...).
    record ConnectionInfo, id : String, remote_address : String?, headers : HTTP::Headers do
      # Stand-in for code that renders outside a WebSocket: the initial HTTP render and tests.
      def self.detached : ConnectionInfo
        new("detached", nil, HTTP::Headers.new)
      end
    end
  end
end

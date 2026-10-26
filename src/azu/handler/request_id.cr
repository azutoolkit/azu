require "http/server/handler"

module Azu
  module Handler
    # Enhanced Request ID handler that integrates with error context
    class RequestId
      include HTTP::Handler

      def initialize(@header_name = "X-Request-ID")
        @header_key = TrustedHeader.key(@header_name)
      end

      def call(context : HTTP::Server::Context)
        # The client's id, unless it is not a valid header value: the wire parser refuses CR, LF, NUL and DEL, but a
        # hand-built request or `HTTP::Headers#merge!` does not, and echoing one could split the response
        supplied = context.request.headers[@header_name]?
        request_id = supplied && context.request.headers.valid_value?(supplied) ? supplied : generate_request_id

        # Set request ID in headers for logging and tracking (Rescuer, SimpleLogger and the application read the
        # request's). The id is generated here or was checked above, so TrustedHeader does not check it again.
        TrustedHeader.set(context.request.headers, @header_key, request_id)
        TrustedHeader.set(context.response.headers, @header_key, request_id)

        RequestContext.scope(context) { |_| call_next(context) }
      end

      private def generate_request_id : String
        RequestContext.generate_id
      end
    end
  end
end

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
        # Generate or extract request ID
        request_id = context.request.headers[@header_name]? || generate_request_id

        # Set request ID in headers for logging and tracking (Rescuer, SimpleLogger and the application read the
        # request's). The id is generated here or a value the request parser already checked, so it is not checked again.
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

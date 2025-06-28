require "http/server/handler"

module Azu
  module Handler
    # Enhanced Request ID handler that integrates with error context
    class RequestId
      include HTTP::Handler

      def initialize(@header_name = "X-Request-ID")
      end

      def call(context : HTTP::Server::Context)
        # Generate or extract request ID
        request_id = context.request.headers[@header_name]? || generate_request_id

        # Set request ID in headers for logging and tracking
        context.request.headers[@header_name] = request_id
        context.response.headers[@header_name] = request_id

        call_next(context)
      end

      private def generate_request_id : String
        "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"
      end
    end
  end
end

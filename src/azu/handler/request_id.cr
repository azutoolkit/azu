require "http/server/handler"

module Azu
  module Handler
    # Enhanced Request ID handler that integrates with error context
    class RequestId
      include HTTP::Handler

      PLAIN_ID_PATTERN = /\A[A-Za-z0-9._:-]+\z/

      getter header_name : String
      getter max_length : Int32
      getter? strict : Bool

      def initialize(@header_name : String = "X-Request-ID", @strict : Bool = false, max_length : Int32? = nil)
        @header_key = TrustedHeader.key(@header_name)
        @strict = true unless max_length.nil?
        @max_length = max_length || 64
      end

      def call(context : HTTP::Server::Context)
        # The client's id, unless it is not a valid header value: the wire parser refuses CR, LF, NUL and DEL, but a
        # hand-built request or `HTTP::Headers#merge!` does not, and echoing one could split the response
        supplied = context.request.headers[@header_name]?
        request_id = if supplied && valid_request_id?(context, supplied)
                       supplied
                     else
                       generate_request_id
                     end

        # Set request ID in headers for logging and tracking (Rescuer, SimpleLogger and the application read the
        # request's). The id is generated here or was checked above, so TrustedHeader does not check it again.
        TrustedHeader.set(context.request.headers, @header_key, request_id)
        TrustedHeader.set(context.response.headers, @header_key, request_id)

        RequestContext.scope(context) { |_| call_next(context) }
      end

      private def valid_request_id?(context : HTTP::Server::Context, supplied : String) : Bool
        return false unless context.request.headers.valid_value?(supplied)

        hygiene = Azu.current_config.hygiene
        if @strict || hygiene.strict_request_id?
          limit = @strict ? @max_length : hygiene.max_request_id_length
          return false if supplied.empty? || supplied.bytesize > limit
          return false unless supplied.matches?(PLAIN_ID_PATTERN)
        end

        true
      end

      private def generate_request_id : String
        RequestContext.generate_id
      end
    end
  end
end

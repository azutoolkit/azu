module Azu
  module Handler
    class RequestID
      include HTTP::Handler

      def initialize(@header = "X-Request-ID")
      end

      def call(context)
        request_id = context.request.headers.fetch(@header) { UUID.random.to_s }
        context.response.headers[@header] = request_id
        call_next context
      end

      private def request_id : String
      end
    end
  end
end

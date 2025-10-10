require "http/server/handler"
require "../error"

module Azu
  module Handler
    class Rescuer
      include HTTP::Handler

      def initialize(@log = Log.for("http.server"))
      end

      def call(context : HTTP::Server::Context)
        call_next(context)
      rescue ex : HTTP::Server::ClientError
        @log.debug(exception: ex.cause) { ex.message }
      rescue ex : Response::Error
        ex.to_s(context)
        context.response.flush unless context.response.closed?
        @log.warn(exception: ex) { "Error Processing Request #{ex.status_code}".colorize(:yellow) }
      rescue ex : Exception
        request_id = context.request.headers["X-Request-ID"]? || generate_request_id
        error_context = ErrorContext.from_http_context(context, request_id)

        enhanced_error = Response::Error.from_exception(ex, 500, error_context)
        enhanced_error.to_s(context)
        context.response.flush unless context.response.closed?

        @log.error(exception: ex) { "Error Processing Request ".colorize(:red) }
      end

      private def generate_request_id : String
        "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"
      end
    end
  end
end

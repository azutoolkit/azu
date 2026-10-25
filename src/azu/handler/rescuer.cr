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
        log_response_error(context, ex)
      rescue ex : Exception
        request_id = context.request.headers["X-Request-ID"]? || generate_request_id
        error_context = ErrorContext.from_http_context(context, request_id, load_environment: Azu.current_config.env.development?)

        enhanced_error = Response::Error.from_exception(ex, 500, error_context)
        enhanced_error.to_s(context)
        context.response.flush unless context.response.closed?

        @log.error(exception: ex) { "Error Processing Request ".colorize(:red) }
      end

      # A 4xx is the client's mistake: one line for the request, no exception and no backtrace (the request logger
      # has the access line already). A 5xx is the server's, and keeps its exception.
      private def log_response_error(context : HTTP::Server::Context, ex : Response::Error) : Nil
        if ex.status_code >= 500
          @log.error(exception: ex) { "Error Processing Request #{ex.status_code}".colorize(:red) }
        else
          @log.debug { "#{context.request.method} #{context.request.path} -> #{ex.status_code} #{ex.title}" }
        end
      end

      private def generate_request_id : String
        "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"
      end
    end
  end
end

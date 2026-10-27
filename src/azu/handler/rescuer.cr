require "http/server/handler"
require "../error"
require "../log_text"

module Azu
  module Handler
    class Rescuer
      include HTTP::Handler

      def initialize(@log = Log.for("Azu::Rescuer"))
        @slow_lines = LogBudget.new
      end

      def call(context : HTTP::Server::Context)
        call_next(context)
      rescue ex : HTTP::Server::ClientError
        @log.debug(exception: ex.cause) { ex.message }
      rescue ex : Response::Error
        publish(context, ex) if ex.status_code >= 500
        ex.to_s(context)
        context.response.flush unless context.response.closed?
        log_response_error(context, ex)
      rescue ex : Exception
        recover(context, ex)
      end

      private def recover(context : HTTP::Server::Context, ex : Exception) : Nil
        return slow_client(context) if ex.is_a?(ServerLimits::ClientTooSlow)

        # The id the request ran under (RequestId opens the scope), so the page, its SQL and the dashboard agree.
        request_id = RequestContext.current?.try(&.request_id) || context.request.headers["X-Request-ID"]? || generate_request_id
        error_context = ErrorContext.from_http_context(context, request_id, load_environment: Azu.current_config.env.development?)

        enhanced_error = Response::Error.from_exception(ex, 500, error_context)
        publish(context, enhanced_error)
        enhanced_error.to_s(context)
        context.response.flush unless context.response.closed?

        @log.error(exception: ex) { "Error Processing Request ".colorize(:red) }
      end

      # A server error goes to the exception subscribers (the dev dashboard keeps it) before it is written, so the page
      # can link to where it is kept. The report is built in development, or when a subscriber listens elsewhere.
      private def publish(context : HTTP::Server::Context, error : Response::Error) : Nil
        return unless Azu.current_config.env.development? || Instrumentation.exception?
        Instrumentation.exception(error.exception_report(context))
      rescue ex
        @log.debug(exception: ex) { "Could not report the exception" }
      end

      # The client stopped sending the request (see `ServerLimitsConfiguration`): not the server's failure, and one line,
      # not a backtrace, however many connections do it.
      private def slow_client(context : HTTP::Server::Context) : Nil
        write, left_out = @slow_lines.take
        @log.warn { "suppressed #{left_out} similar slow requests in the last second" } if left_out > 0
        @log.warn { "#{context.request.method} #{context.request.path} -> 408 the client was too slow to send the request" } if write
        return if context.response.wrote_headers?

        context.response.status = :request_timeout
        context.response.headers["Connection"] = "close"
        context.response.content_length = 0
      end

      # A 4xx is the client's mistake: one line for the request with the reason, no exception and no backtrace (the
      # request logger has the access line already); 401, 403, 413 and 429 are louder (see `LogText`). A 5xx is the
      # server's, and keeps its exception.
      private def log_response_error(context : HTTP::Server::Context, ex : Response::Error) : Nil
        if ex.status_code >= 500
          @log.error(exception: ex) { "Error Processing Request #{ex.status_code}".colorize(:red) }
        else
          LogText.log_refusal(@log, context.request, ex)
        end
      end

      private def generate_request_id : String
        "req_#{Time.utc.to_unix_ms}_#{Random::Secure.hex(8)}"
      end
    end
  end
end

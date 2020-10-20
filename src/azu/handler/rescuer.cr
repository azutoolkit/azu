module Azu
  module Handler
    class Rescuer
      include HTTP::Handler

      def initialize(@verbose : Bool = CONFIG.env.development?, @log = Log.for("http.server"))
      end

      def call(context)
        call_next(context)
      rescue ex
        handle(context, ex)
      end

      def handle(context, ex)
        case ex
        when HTTP::Server::ClientError
          @log.debug(exception: ex.cause) { ex.message }
        when Response::Error
          unless context.response.closed? || context.response.wrote_headers?
            context.response.reset
            context.response.status = ex.status
            context.response.puts(ex.inspect_with_backtrace)
            ContentNegotiator.content context, ex
          end
        else
          @log.error(exception: ex) { "Unhandled exception" }
          unless context.response.closed? || context.response.wrote_headers?
            if @verbose
              context.response.reset
              context.response.status = :internal_server_error
              context.response.content_type = "text/plain"
              context.response.print("ERROR: ")
              context.response.puts(ex.inspect_with_backtrace)
            else
              context.response.respond_with_status(:internal_server_error)
            end
          end
        end
      end
    end
  end
end

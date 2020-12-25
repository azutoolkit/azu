module Azu
  module Handler
    class Rescuer
      include HTTP::Handler

      def initialize(@verbose : Bool = true, @log = Log.for("http.server"))
      end

      def call(context)
        call_next(context)
      rescue ex
        handle(context, ex)
      end

      def handle(context, ex)
        @log.error(exception: ex) { ex.message }
        case ex
        when HTTP::Server::ClientError
          @log.debug(exception: ex.cause) { ex.message }
        when Response::Error
          unless context.response.closed? || context.response.wrote_headers?
            context.response.reset
            context.response.status = ex.status
            ContentNegotiator.content context, ex
          end
        else
          if @verbose
            context.response.reset
            context.response.status = :internal_server_error
            context.response.content_type = "text/plain"
            context.response.print("ERROR: ")
          else
            context.response.respond_with_status(:internal_server_error)
          end
        end
      end
    end
  end
end

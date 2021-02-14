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
        context.response.status_code = ex.status_code
        ContentNegotiator.content_type context
        Log.warn(exception: ex) { "Error Processing Request #{ex.status_code}".colorize(:yellow) }
      rescue ex : Exception
        error = Response::Error.from_exception ex
        ContentNegotiator.content_type context
        Log.error(exception: ex) { "Error Processing Request ".colorize(:red) }
      end
    end
  end
end

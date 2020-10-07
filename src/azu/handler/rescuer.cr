require "exception_page"

module Azu
  module Handler
    class Rescuer
      include HTTP::Handler

      class ExceptionPage < ::ExceptionPage
        def styles : ExceptionPage::Styles
          ::ExceptionPage::Styles.new(
            accent: "red",
          )
        end
      end

      def self.handle_error(context, ex)
        new.handle_error context, ex
      end

      def call(context : HTTP::Server::Context)
        call_next(context)
      rescue ex
        handle_error context, ex
      end

      def handle_error(context, ex : Exception)
        error = Response::Error.from_exception ex
        handle_error(context, error)
      end

      def handle_error(context, ex : Response::Error)
        ex.print_log
        context.response.status = ex.status
        if ENVIRONMENT.development?
          context.response.print ExceptionPage.for_runtime_exception(context, ex)
          return context
        end
        ContentNegotiator.content context, ex
        context
      end
    end
  end
end

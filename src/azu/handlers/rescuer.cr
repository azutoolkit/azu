module Azu
  class Rescuer
    include HTTP::Handler

    def call(context)
      call_next(context)
    rescue ex : Azu::Error
      ex.print_log
      render(context, ex)
    rescue ex : Exception
      error = Error.from_exception(ex)
      error.print_log
      render(context, error)
    end

    private def render(context, error)
      view = ErrorView.new(context, error)
      context.response.reset
      context.response.status_code = error.status
      context.response.print ContentNegotiator.content(context, view)
      context
    end
  end
end

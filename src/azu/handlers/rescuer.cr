module Azu
  class Rescuer
    include HTTP::Handler

    def call(context)
      call_next(context) if self.next
    rescue ex : Azu::Error
      ex.print_log
      ex.render(context)
    rescue ex : Exception
      error = Error.from_exception(ex)
      error.print_log
      error.render(context)
    end
  end
end

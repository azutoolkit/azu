module Azu
  class Rescuer
    include HTTP::Handler

    def call(context)
      call_next(context) if self.next
    rescue ex : Azu::Error
      ex.render(context)
    rescue ex : Exception
      Error.from_exception(ex).render(context)
    end
  end
end

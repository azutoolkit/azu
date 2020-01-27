module Azu
  class View
    def call(context)
      return call_next(context) if context.response.upgraded? && self.next

      # Continue processing before rendering
      call_next(context) if self.next

      if accept = context.request.accept
        accept.each do |a|
          case a.media_type
          when "text/html"         then view.html(context.response)
          when "application/json"  then view.json(context.response)
          when "text/plain", "*/*" then view.text(context.response)
          end
        end
      end
    end
  end
end

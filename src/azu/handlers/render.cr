module Azu
  class Render
    include HTTP::Handler

    class NotAcceptable < Error(406)
    end

    def call(context)
      route = context.request.route.not_nil!
      _namespace, endpoint = route.payload.not_nil!
      
      if view = endpoint.new(context, route.params).call
        return context if context.request.ignore_body?
        
        context.response.output << render(context, view).to_s
      end

      call_next(context) if self.next
    end

    private def render(context, view)
      accept = context.request.accept
      raise NotAcceptable.new unless accept

      accept.each do |a|
        case a.sub_type.not_nil!
        when .includes? "html"  
          context.response.content_type = a.to_s
          return view.html
        when .includes? "json" 
          context.response.content_type = a.to_s
          return view.json
        when .includes? "plain" 
          context.response.content_type = a.to_s
          return view.text
        when .includes? "*" 
          context.response.content_type = a.to_s
          return view.text
        else raise NotAcceptable.new
        end
      end
    end
  end
end

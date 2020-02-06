module Azu
  class Render
    include HTTP::Handler

    def call(context)
      route = context.request.route.not_nil!
      _namespace, endpoint = route.payload.not_nil!

      if view = endpoint.new(context, route.params).call
        return context if context.request.ignore_body?
        return context if (300..308).includes? context.response.status_code

        context.response.output << content(context, view)
      end

      call_next(context) if self.next

      context
    end

    def content(context, view : Nil)
      context.response.status_code = 204
      ""
    end

    def content(context, view : String)
      context.response.content_type = "text/plain"
      view
    end

    def content(context, view : Azu::View)
      accept = context.request.accept
      unless accept
        return NotAcceptable.new.render(context)
      end
      accept.each do |a|
        case a.sub_type.not_nil!
        when "html"
          context.response.content_type = a.to_s
          return view.html
        when "json"
          context.response.content_type = a.to_s
          return view.json
        when "xml"
          context.response.content_type = a.to_s
          return view.xml
        when "plain", "*"
          context.response.content_type = a.to_s
          return view.text
        else
          return view
        end
      end
    end
  end
end

module Azu
  class Render
    include HTTP::Handler
    NOT_ACCEPTABLE_MSG = <<-TITLE
    The server cannot produce a response matching the list of 
    acceptable values defined in the request's proactive content 
    negotiation headers
    TITLE

    def call(context)
      route = context.request.route.not_nil!
      _namespace, endpoint = route.payload.not_nil!

      if view = endpoint.new(context, route.params).call
        return context if context.request.ignore_body?
        return context if (300..310).includes? context.response.status_code
        return context if  context.response
        context.response.output << render(context, view).to_s
      end

      call_next(context) if self.next
      context
    end

    def error(context : HTTP::Server::Context, ex : Azu::Error)
      view = Views::Error.new(context, ex)
      context.response.output << render(context, view)
      call_next(context) if self.next
      context
    end

    private def render(context, view)
      accept = context.request.accept
      return view.text unless accept

      case view
      when String 
        context.response.content_type = "text/plain"
        return view
      when Azu::View
        accept.each do |a|
          case a.sub_type.not_nil!
          when "html"
            context.response.content_type = a.to_s
            return view.html
          when "json"
            context.response.content_type = a.to_s
            return view.json
          when "plain", "*"
            context.response.content_type = a.to_s
            return view.text
          else
            raise NotAcceptable.new(detail: NOT_ACCEPTABLE_MSG, source: context.request.path)
          end
        end
      else
        raise NotAcceptable.new(detail: NOT_ACCEPTABLE_MSG, source: context.request.path)
      end
    end
  end
end

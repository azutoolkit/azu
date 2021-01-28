module Azu
  # :nodoc:
  module ContentNegotiator
    extend self

    def content(context, view : Nil)
      context.response.reset
      context.response.status_code = 204
      context.response.print ""
    end

    def content(context, body : String | Response::Text)
      context.response.content_type = "text/plain"
      context.response.print body.to_s
    end

    def content(context, body : Response::Html)
      context.response.content_type = "text/html"
      context.response.print body.to_s
    end

    def content(context, body : JSON | Response::Json)
      context.response.content_type = "application/json"
      context.response.print body.to_s
    end

    def content(context, body : XML | Response::Xml)
      context.response.content_type = "application/xml"
      context.response.print body.to_s
    end

    def content(context, view : Response | Response::Error)
      if context.response.headers["content_type"]?
        context.response.print view.to_s
        return
      end

      if accept = context.request.accept
        accept.each do |a|
          case a.sub_type.not_nil!
          when .includes?("html")
            context.response.content_type = a.to_s
            if view.is_a? Response::Error
              context.response.print view.html(context)
            else
              context.response.print view.html
            end
            break
          when .includes?("json")
            context.response.content_type = a.to_s
            context.response.print view.json
            break
          when .includes?("xml")
            context.response.content_type = a.to_s
            context.response.print view.xml
            break
          when .includes?("plain"), "*"
            context.response.content_type = a.to_s
            context.response.print view.text
            break
          else
            context.response.content_type = a.to_s
            context.response.print view.text
            break
          end
        end
      end
    end
  end
end

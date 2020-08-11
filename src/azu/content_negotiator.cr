module Azu
  module ContentNegotiator
    extend self

    def content(context, view : Nil)
      context.response.reset
      context.response.status_code = 204
      context.response.print ""
    end

    def content(context, body : String | Azu::Text)
      context.response.content_type = "text/plain"
      context.response.print body.to_s
    end

    def content(context, body : Azu::Html)
      context.response.content_type = "text/html"
      context.response.print body.to_s
    end

    def content(context, body : JSON | Azu::Json)
      context.response.content_type = "application/json"
      context.response.print body.to_s
    end

    def content(context, body : XML | Azu::Xml)
      context.response.content_type = "application/xml"
      context.response.print body.to_s
    end

    def content(context, view : Azu::Response)
      if accept = context.request.accept
        accept.each do |a|
          case a.sub_type.not_nil!
          when .includes?("html")
            context.response.content_type = a.to_s
            context.response.print view.html
          when .includes?("json")
            context.response.content_type = a.to_s
            context.response.print view.json
          when .includes?("xml")
            context.response.content_type = a.to_s
            context.response.print view.xml
          when .includes?("plain"), "*"
            context.response.content_type = a.to_s
            context.response.print view.text
          else
            next
          end
        end
      else
        context.response.content_type = "text/plain"
        context.response.print view.to_s
      end
    end
  end
end

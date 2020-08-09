module Azu
  module ContentNegotiator
    extend self

    def content(context, view : Nil)
      context.response.reset
      context.response.status_code = 204
      ""
    end

    def content(context, view : String | Azu::Text)
      context.response.content_type = "text/plain"
      view
    end

    def content(context, view : JSON | Azu::Html)
      context.response.content_type = "application/json"
      view.html
    end

    def content(context, view : JSON | Azu::Json)
      context.response.content_type = "application/json"
      view.json
    end

    def content(context, view : XML | Azu::Xml)
      context.response.content_type = "application/xml"
      view.xml
    end

    def content(context, view : Azu::View)
      accept = context.request.accept
      return view.text unless accept

      accept.each do |a|
        case a.sub_type.not_nil!
        when .includes?("html")
          context.response.content_type = a.to_s
          return view.html
        when .includes?("json")
          context.response.content_type = a.to_s
          return view.json
        when .includes?("xml")
          context.response.content_type = a.to_s
          return view.xml
        when .includes?("plain"), "*"
          context.response.content_type = a.to_s
          return view.text
        else
          next
        end
      end
    end
  end
end

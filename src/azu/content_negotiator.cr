module Azu
  # :nodoc:
  module ContentNegotiator
    def self.content_type(context)
      return if context.response.headers["content_type"]?

      if accept = context.request.accept
        accept.each do |a|
          case a.sub_type.not_nil!
          when .includes?("html")
            context.response.content_type = a.to_s
            break
          when .includes?("json")
            context.response.content_type = a.to_s
            break
          when .includes?("xml")
            context.response.content_type = a.to_s
            break
          when .includes?("plain"), "*"
            context.response.content_type = a.to_s
            break
          else
            context.response.content_type = a.to_s
            break
          end
        end
      end
    end
  end
end

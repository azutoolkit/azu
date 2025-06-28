module Azu
  # :nodoc:
  module ContentNegotiator
    def self.content_type(context)
      return if context.response.headers["content_type"]?

      if accept = context.request.accept
        accept.each do |a|
          # Extract just the basic media type without parameters
          basic_type = a.to_s.split(';').first.strip

          case a.sub_type.not_nil!
          when .includes?("html")
            context.response.content_type = basic_type
            break
          when .includes?("json")
            context.response.content_type = basic_type
            break
          when .includes?("xml")
            context.response.content_type = basic_type
            break
          when .includes?("plain"), "*"
            context.response.content_type = basic_type
            break
          else
            context.response.content_type = basic_type
            break
          end
        end
      end
    end
  end
end

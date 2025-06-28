require "mime"

# :nodoc:
class HTTP::Request
  @path_params = {} of String => String
  @accept : Array(MIME::MediaType)? = nil

  def content_type : MIME::MediaType
    if content = headers["Content-Type"]?
      MIME::MediaType.parse(content)
    else
      MIME::MediaType.parse("text/plain")
    end
  end

  def path_params
    @path_params
  end

  def path_params=(params)
    @path_params = params
  end

  def accept : Array(MIME::MediaType) | Nil
    @accept ||= (
      if header = headers["Accept"]?
        # Handle empty or whitespace-only accept headers
        return nil if header.strip.empty?

        header.split(",").map do |a|
          trimmed = a.strip
          next if trimmed.empty?
          MIME::MediaType.parse(trimmed)
        end.compact.sort! do |a, b|
          (b["q"]?.try &.to_f || 1.0) <=> (a["q"]?.try &.to_f || 1.0)
        end
      end
    )
  end
end

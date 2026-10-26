require "mime"

# :nodoc:
class HTTP::Request
  @path_params : Hash(String, String)? = nil
  @accept : Array(MIME::MediaType)? = nil

  def content_type : MIME::MediaType
    if content = headers["Content-Type"]?
      MIME::MediaType.parse(content)
    else
      MIME::MediaType.parse("text/plain")
    end
  end

  def path_params : Hash(String, String)
    @path_params ||= {} of String => String
  end

  # Nil forgets them: the router writes nil for a route without parameters, which a mounted app's router does after
  # the mount's own route wrote its `mount_path`.
  def path_params=(params : Hash(String, String)?)
    @path_params = params
  end

  def accept : Array(MIME::MediaType) | Nil
    @accept ||= (
      if header = headers["Accept"]?
        # Handle empty or whitespace-only accept headers
        return nil if header.strip.empty?

        header.split(",").compact_map do |accept_type|
          trimmed = accept_type.strip
          next if trimmed.empty?
          MIME::MediaType.parse(trimmed)
        end.sort! do |media_type_a, media_type_b|
          (media_type_b["q"]?.try &.to_f || 1.0) <=> (media_type_a["q"]?.try &.to_f || 1.0)
        end
      end
    )
  end
end

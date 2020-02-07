require "mime"

class HTTP::Request
  @route = uninitialized Radix::Result(Tuple(Symbol, Azu::Endpoint.class))
  @accept : Array(MIME::MediaType)? = nil

  def content_type : MIME::MediaType
    if content = headers["Content-Type"]?
      MIME::MediaType.parse(content)
    else
      MIME::MediaType.parse("text/plain")
    end
  end

  def route
    @route
  end

  def route=(other)
    @route = other
  end

  def accept : Array(MIME::MediaType) | Nil
    @accept ||= (
      if header = headers["Accept"]?
        header.split(",").map { |a| MIME::MediaType.parse(a) }.sort do |a, b|
          (b["q"]?.try &.to_f || 1.0) <=> (a["q"]?.try &.to_f || 1.0)
        end
      end
    )
  end
end

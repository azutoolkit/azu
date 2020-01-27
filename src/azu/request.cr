require "mime"

class HTTP::Request
  property route : Radix::Result(Tuple(Symbol, Azu::Endpoint.class))? = nil
  @accept : Array(MIME::MediaType)? = nil

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

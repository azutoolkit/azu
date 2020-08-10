require "mime"

module Azu
  module Request
    getter params : Params

    @accept : Array(MIME::MediaType)? = nil

    def content_type : MIME::MediaType
      if content = headers["Content-Type"]?
        MIME::MediaType.parse(content)
      else
        MIME::MediaType.parse("text/plain")
      end
    end

    def method
      Method.parse(method)
    end

    def header
      headers
    end

    def body
      @request.body.not_nil!.gets_to_end
    end

    def json
      JSON.parse(body.to_s)
    end

    def header(key : String, value : String)
      @response.headers[key] = value
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
end

module Azu
  # A collection of methods that allows you to work with the HTTP message (`Request`, `Response`)
  module Helpers
    private def context
      @context.not_nil!
    end

    private def method
      Method.parse(context.request.method)
    end

    private def header
      context.request.headers
    end

    private def json
      JSON.parse(body.to_s)
    end

    private def cookies
      context.request.cookies
    end

    private def header(key : String, value : String)
      context.response.headers[key] = value
    end

    private def redirect(to location : String, status : Int32 = 301)
      status status
      header "Location", location
    end

    private def cookies(cookie : HTTP::Cookie)
      context.response.cookies << cookie
    end

    private def status(status : Int32)
      context.response.status_code = status
    end

    private def error(detail : String, status : Int32 = 400, errors = [] of String)
      Response::Error.new(detail, HTTP::Status.new(status), errors)
    end
  end
end

module Helpers
  private def method
    Method.parse(context.request.method)
  end

  private def headers
    context.request.headers
  end

  private def headers(key : String, value : String)
    context.response.headers[key] = value
  end

  private def redirect(to : String, status : Int32)
  end

  private def redirect(to : Endpoint, status : Int32)
  end

  private def cookies
    context.request.cookies
  end

  private def cookies(cookie : HTTP::Cookie)
    context.response.cookies << cookie
  end

  private def status(status : HTTP::Status)
    context.response.status = status
  end

  private def status(status : Int32)
    context.response.status = HTTP::Status.new(status_code)
  end
end

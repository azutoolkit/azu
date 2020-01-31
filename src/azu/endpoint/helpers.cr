module Helpers
  def method
    Method.parse(context.request.method)
  end

  def header
    context.request.headers
  end

  def header(key : String, value : String)
    context.response.headers[key] = value
  end

  def redirect(to locaton : String, status : Int32)
    status status
    header location
  end

  def cookies
    context.request.cookies
  end

  def cookies(cookie : HTTP::Cookie)
    context.response.cookies << cookie
  end

  def status(status : Int32)
    context.response.status_code = status
  end
end

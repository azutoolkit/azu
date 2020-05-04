module Azu
  abstract class Endpoint
    include HTTP::Handler

    @context = uninitialized HTTP::Server::Context
    @params : Params | Nil = nil

    def call(context : HTTP::Server::Context)
      @context = context
      context.response.print ContentNegotiator.content(context, call)

      @context
    end

    abstract def call

    private def context
      @context
    end

    private def params
      Params.new(@context.request)
    end

    private def method
      Method.parse(@context.request.method)
    end

    private def header
      @context.request.headers
    end

    private def body
      @context.request.body.not_nil!.gets_to_end
    end

    private def json
      JSON.parse(body.to_s)
    end

    private def header(key : String, value : String)
      @context.response.headers[key] = value
    end

    private def redirect(to location : String, status : Int32 = 301)
      status status
      header "Location", location
    end

    private def cookies
      @context.request.cookies
    end

    private def cookies(cookie : HTTP::Cookie)
      @context.response.cookies << cookie
    end

    private def status(status : Int32)
      @context.response.status_code = status
    end

    private def error(title, message, status_code)
      error = Azu::Error.new(detail: message)
      error.title = title
      error.status = status_code
      error.render(@context)
    end
  end
end

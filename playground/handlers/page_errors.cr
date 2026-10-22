require "../../src/azu"

module ExampleApp
  # Turns errors into a friendly HTML page when the client asks for HTML. API clients
  # (any other Accept header) still get the framework's JSON/text error, and in development
  # unexpected exceptions still reach the debug page.
  class PageErrors
    include HTTP::Handler

    HEADLINES = {
      400 => "That request didn't look right",
      401 => "Please sign in first",
      403 => "You can't open that",
      404 => "We couldn't find that page",
      422 => "Some details need another look",
      429 => "Slow down a little",
      500 => "Something broke on our side",
      502 => "A partner service is having a moment",
      504 => "That took too long",
    }

    def call(context : HTTP::Server::Context)
      call_next(context)
    rescue ex : Azu::Response::Error
      raise ex unless wants_html?(context)
      render(context, ex.status_code, ex.detail, ex.errors)
    rescue ex : HTTP::Server::ClientError
      raise ex
    rescue ex : Exception
      raise ex if Azu::CONFIG.env.development? || !wants_html?(context)
      render(context, 500, "An unexpected error occurred. It has been logged.", [] of String)
    end

    private def wants_html?(context : HTTP::Server::Context) : Bool
      context.request.headers["Accept"]?.try(&.includes?("text/html")) || false
    end

    private def render(context : HTTP::Server::Context, code : Int32, detail : String, errors : Array(String)) : Nil
      context.response.status_code = code
      context.response.content_type = "text/html"
      headline = HEADLINES[code]? || HTTP::Status.new(code).description || "Something went wrong"
      kind = code >= 500 ? "bad" : (code == 404 ? "info" : "warn")
      context.response.print Page.new(
        "error_page.html", context, "errors",
        code: code, headline: headline, detail: detail, errors: errors, kind: kind,
        request_id: context.request.headers["X-Request-ID"]?
      ).render
    end
  end
end

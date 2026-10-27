require "http/server/handler"
require "./document"
require "./docs_page"

module Azu::OpenAPI
  # Serves the OpenAPI document of an app as JSON at `path` (GET and HEAD), without reaching the rest
  # of the chain, and with `docs:` an HTML reference of it at that path. Opt in by adding it to the
  # handlers of the server:
  #
  # ```
  # app.server([Azu::OpenAPI::Handler.new(app, info: Azu::OpenAPI::Info.new("Shop API", "1.0.0"), docs: "/docs")] of HTTP::Handler)
  # ```
  #
  # The document is built by the first request and kept: routes added later do not show up.
  class Handler
    include HTTP::Handler

    @docs : String?

    def initialize(@app : App, *, @info : Info, path : String = "/openapi.json", @servers : Array(Server) = [] of Server, docs : String? = nil)
      @path = path.rstrip('/')
      @docs = docs.try(&.rstrip('/'))
      raise ArgumentError.new("The docs page cannot be served at the document's path #{path}") if @docs == @path
      @lock = Mutex.new
      @document = nil.as(Document?)
      @json = nil.as(String?)
      @html = nil.as(String?)
    end

    def call(context : HTTP::Server::Context)
      request = context.request
      return call_next(context) unless {"GET", "HEAD"}.includes?(request.method)

      case request.path.rstrip('/')
      when @path then answer(context, "application/json", json)
      when @docs then answer(context, "text/html; charset=utf-8", html, DocsPage::POLICY)
      else            call_next(context)
      end
    end

    private def answer(context : HTTP::Server::Context, content_type : String, body : String, policy : String? = nil) : Nil
      response = context.response
      response.content_type = content_type
      policy.try { |value| response.headers["Content-Security-Policy"] = value }
      response.content_length = body.bytesize
      response << body unless context.request.method == "HEAD"
    end

    private def json : String
      @lock.synchronize { @json ||= document.to_json }
    end

    private def html : String
      @lock.synchronize { @html ||= DocsPage.render(document.to_h, @path.empty? ? "/" : @path) }
    end

    # Built once, under the lock its callers hold.
    private def document : Document
      @document ||= OpenAPI.document(@app, @info, @servers)
    end
  end
end

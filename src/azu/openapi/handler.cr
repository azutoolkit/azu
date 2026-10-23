require "http/server/handler"
require "./document"

module Azu::OpenAPI
  # Serves the OpenAPI document of an app as JSON at `path` (GET and HEAD), without reaching the rest
  # of the chain. Opt in by adding it to the handlers of the server:
  #
  # ```
  # app.server([Azu::OpenAPI::Handler.new(app, info: Azu::OpenAPI::Info.new("Shop API", "1.0.0"))] of HTTP::Handler)
  # ```
  #
  # The document is built by the first request and kept: routes added later do not show up.
  class Handler
    include HTTP::Handler

    def initialize(@app : App, *, @info : Info, path : String = "/openapi.json", @servers : Array(Server) = [] of Server)
      @path = path.rstrip('/')
      @lock = Mutex.new
      @json = nil.as(String?)
    end

    def call(context : HTTP::Server::Context)
      return call_next(context) unless context.request.path.rstrip('/') == @path && {"GET", "HEAD"}.includes?(context.request.method)

      body = json
      response = context.response
      response.content_type = "application/json"
      response.content_length = body.bytesize
      response << body unless context.request.method == "HEAD"
    end

    private def json : String
      @lock.synchronize { @json ||= OpenAPI.document(@app, @info, @servers).to_json }
    end
  end
end

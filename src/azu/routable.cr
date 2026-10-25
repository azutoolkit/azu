require "http/server"
require "./openapi/operation"

module Azu
  # Anything the router can dispatch a request to: an endpoint, a WebSocket upgrader or any plain
  # `HTTP::Handler`. Endpoints are routable but deliberately not `HTTP::Handler`s: a handler carries
  # a `next` link to the following handler, and a struct endpoint holding that link contains itself.
  module Routable
    abstract def call(context : HTTP::Server::Context)

    # What the OpenAPI document says about this route, read from the contract. Nil for a routable
    # that has none, which is then left out of the document. `Endpoint` overrides this.
    def openapi_operation : OpenAPI::Operation?
      nil
    end
  end
end

# Every handler can be routed to. This is a module-in-module include rather than a union type
# (`Routable | HTTP::Handler`), which makes the compiler emit a null call for struct endpoints.
module HTTP::Handler
  include Azu::Routable
end

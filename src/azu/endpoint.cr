require "./helpers"

module Azu
  abstract class Endpoint
    include HTTP::Handler
    include Helpers

    @context = uninitialized HTTP::Server::Context

    def call(context : HTTP::Server::Context)
      @context = context
      context.response.print ContentNegotiator.content(@context, call)
      @context
    end

    abstract def call
  end
end

require "./helpers"

module Azu
  module Endpoint(R, V)
    include HTTP::Handler
    include Helpers

    @context = uninitialized HTTP::Server::Context

    abstract def call : V

    def call(context : HTTP::Server::Context)
      @context = context
      ContentNegotiator.content @context, call
      call_next(context)
      @context
    end

    private def request
      R.new @context
    end
  end
end

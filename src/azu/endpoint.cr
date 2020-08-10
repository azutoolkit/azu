require "./helpers"

module Azu
  module Endpoint(R, V)
    include HTTP::Handler

    @context = uninitialized HTTP::Server::Context

    abstract def call : V

    def call(context : HTTP::Server::Context)
      @context = context
      ContentNegotiator.content @context, call
      @context
    end

    private def request
      R.new @context
    end
  end
end

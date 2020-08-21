require "mime"

module Azu
  module Request
    include Helpers
    include Schema::Validation
    getter context : HTTP::Server::Context
    getter params : Params

    @accept : Array(MIME::MediaType)? = nil

    forward_missing_to @context.request

    def initialize(@context : HTTP::Server::Context)
      @params = Params.new(@context.request)
    end
  end
end

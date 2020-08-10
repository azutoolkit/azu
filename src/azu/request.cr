require "mime"

module Azu
  module Request
    include Helpers

    getter context : HTTP::Server::Context
    getter params : Params

    @accept : Array(MIME::MediaType)? = nil

    def initialize(@context : HTTP::Server::Context)
    end

    def params
      @params ||= Params.new(@context.request)
    end
  end
end

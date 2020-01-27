module Azu
  class Endpoint
    getter context : HTTP::Server::Context
    getter path_params : Hash(String, String)
    getter params

    def initialize(@context, @path_params)
      @params = Params.new(context.request)
    end

    def call
    end
  end
end

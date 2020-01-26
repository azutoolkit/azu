module Azu
  class Endpoint
    getter context : HTTP::Server::Context
    getter path_params : Hash(String, String)?

    def initialize(@context, @path_params = nil)
    end

    def call
    end
  end
end

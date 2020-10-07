require "mime"

module Azu
  # Every HTTP request message has a specific form:
  #
  # ```text
  # POST /path HTTP/1.1
  # Host: example.com
  #
  # foo=bar&baz=bat
  # ```
  #
  # A HTTP message is either a request from a client to a server or a response from a server to a client
  # The `Azu::Request` represents a client request and it provides additional helper methods to access different
  # parts of the HTTP Request extending the Crystal `HTTP::Request` standard library class.
  # These methods are define in the `Helpers` class.
  #
  module Request
    include Helpers
    include Schema::Validation

    getter context : HTTP::Server::Context
    getter params : Params

    forward_missing_to @context.request

    def initialize(@context : HTTP::Server::Context)
      @params = Params.new(@context.request)
    end
  end
end

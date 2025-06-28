require "mime"
require "uri/params/serializable"

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
  # Azu Request are design by contract in order to enforce correctness. What this means is that requests
  # are strictly typed and can have pre-conditions. With this concept Azu::Request provides a consice way
  # to type safe and validate requests objects.
  #
  # Azu Requests benefits:
  #
  # * Self documented request objects.
  # * Type safe requests and parameters
  # * Enables Focused and effective testing.
  # * Json body requests render object instances.
  #
  # Azu Requests contracts is provided by tight integration with Crystal's built-in URI::Params::Serializable
  # and the [Schema](https://github.com/eliasjpr/schema) shard for validation
  #
  # ### Example Use:
  #
  # ```
  # class UserRequest
  #   include Azu::Request
  #
  #   @name : String
  #   validate name, presence: true, message: "Name param must be present!"
  # end
  # ```
  #
  # ### Initializers
  #
  # ```
  # UserRequest.from_json(payload: String)
  # UserRequest.from_www_form(params: String)
  # UserRequest.new(name: "value")
  # ```
  #
  # ### Available Methods
  #
  # ```
  # getters       - For each of the params
  # valid?        - Bool
  # validate!     - True or Raise Error
  # errors        - Errors(T, S)
  # rules         - Rules(T, S)
  # to_www_form   - Outputs URL-encoded form
  # to_json       - Outputs JSON
  # to_yaml       - Outputs YAML
  # ```
  module Request
    macro included
      include JSON::Serializable
      include URI::Params::Serializable
      include Schema::Validation

      def error_messages
        errors.map(&.message)
      end

      # Compatibility method for existing endpoints that use from_query
      def self.from_query(query_string : String)
        from_www_form(query_string)
      end
    end
  end
end

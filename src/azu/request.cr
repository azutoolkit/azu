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
  # Azu Requests contracts is provided by tight integration with the [Schema](https://github.com/eliasjpr/schema) shard
  #
  # ### Example Use:
  #
  # ```crystal
  # class UserRequest
  #   include Azu::Request
  #
  #   query name : String, message: "Param name must be present.", presence: true
  # end
  # ```
  #
  # ### Initializers
  #
  # ```crystal
  # UserRequest.from_json(pyaload: String)
  # UserRequest.new(params: Hash(String, String))
  # ```
  #
  # ### Available Methods
  #
  # ```crystal
  # getters   - For each of the params
  # valid?    - Bool
  # validate! - True or Raise Error
  # errors    - Errors(T, S)
  # rules     - Rules(T, S)
  # params    - Original params payload
  # to_json   - Outputs JSON
  # to_yaml   - Outputs YAML
  # ```
  #
  module Request
    macro included
      include JSON::Serializable
      include Schema::Definition
      include Schema::Validation

      def error_messages
        errors.map(&.message)
      end
    end
  end
end

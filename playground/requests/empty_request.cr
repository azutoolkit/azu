require "../../src/azu"

module ExampleApp
  # Empty request for endpoints that don't need specific request parameters
  struct EmptyRequest
    include Azu::Request
  end
end

require "../../src/azu"

module ExampleApp
  # Generic JSON response that can handle any serializable data
  struct GenericJsonResponse
    include Azu::Response

    @data : String

    def initialize(data)
      @data = data.to_json
    end

    def render
      @data
    end
  end
end

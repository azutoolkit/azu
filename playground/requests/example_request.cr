require "../../src/azu"

module ExampleApp
  struct ExampleReq
    include Azu::Request

    BAD_REQUEST = "Error validating request"

    @name : String
    getter name

    def initialize(@name : String = "")
    end

    validate name, presence: true, message: "Name param must be present!"
  end
end

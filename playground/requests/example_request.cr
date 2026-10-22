require "../../src/azu"

module ExampleApp
  struct ExampleReq
    include Azu::Request

    BAD_REQUEST = "Error validating request"

    # Defaults to "" so a missing name is a validation message, not a 400 from the parser.
    @name : String = ""

    def initialize(@name : String = "")
    end

    def name : String
      @name.strip
    end

    validate name, presence: true, message: "Name param must be present!"
  end
end

module ExampleApp
  struct ExampleReq
    include Azu::Request

    BAD_REQUEST = "Error validating request"
    getter name : String
    
    validate name, presence: true, message: "Name param must be present!"
  end
end

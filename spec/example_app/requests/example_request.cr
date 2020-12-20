module ExampleApp
  struct ExampleReq
    include Azu::Request

    BAD_REQUEST = "Error validating request"

    path name : String, presence: true, message: "Name param must be present!"

    def verify!
      Response::BadRequest.new BAD_REQUEST, "/path", errors.messages unless valid?
    end
  end
end

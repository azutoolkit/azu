module ExampleApp
  struct ExampleReq
    include Azu::Request
    include Azu::Contract

    BAD_REQUEST = "Error validating request"

    query name : String, presence: true, message: "Name param must be present!"

    def verify!
      raise BadRequest.new BAD_REQUEST, path, errors.messages unless valid?
    end
  end
end

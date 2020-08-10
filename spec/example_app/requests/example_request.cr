module ExampleApp
  struct ExampleReq
    include Azu::Request
    include Azu::Contract

    query name : String, presence: true, message: "Name param must be present!"
  end
end

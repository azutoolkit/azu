require "json"

module ExampleApp
  struct JsonReq
    include Request

    property! id : Int64
    property! users : Array(String)
    property! config : Hash(String, String)

    def initialize(params : Azu::Params)
    end
    

    validate id, eq: 3
  end
end

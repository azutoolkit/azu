require "json"

module ExampleApp
  struct JsonReq
    include Request

    property! users : Array(String)
    property! config : Hash(String, String)

    def initialize(params : Azu::Params)
    end

    path id : Int64, eq: 3
  end
end

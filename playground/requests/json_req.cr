require "json"

module ExampleApp
  struct JsonReq
    include Request

    getter id : Int64? = nil
    getter users : Array(String)
    getter config : Config

    struct Config
      include Request
      property? allowed : Bool = false
    end
  end
end

require "json"

module ExampleApp
  struct JsonReq
    include Request

    getter id : Int64? = nil
    getter users : Array(String)
    getter config : Hash(String, String)
  end
end

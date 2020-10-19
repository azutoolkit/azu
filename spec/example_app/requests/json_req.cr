require "json"

module ExampleApp
  struct JsonReq
    include Azu::Request
    include JSON::Serializable

    property! id : Int64 
    property! users : Array(String)
    property! config : Hash(String, String)
  end
end
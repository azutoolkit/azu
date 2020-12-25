module ExampleApp
  class JsonEndpoint
    include Azu::Endpoint(JsonReq, JsonRes)
    
    def call : JsonRes
      raise error("Invalid JSON", 400, json_req.error_messages) unless json_req.valid?
      JsonRes.new json_req
    end
  end
end

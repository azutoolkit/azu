module ExampleApp
  struct JsonEndpoint
    include Endpoint(JsonReq, JsonRes)

    post "/json/:id", accept: "application/json", content_type: "application/json"

    def call : JsonRes
      raise error("Invalid JSON", 400, json_req.error_messages) unless json_req.valid?
      JsonRes.new json_req
    end
  end
end

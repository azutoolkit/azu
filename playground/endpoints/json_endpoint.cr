module ExampleApp
  struct JsonEndpoint
    include Endpoint(JsonReq, JsonResponse)
    post "/json/:id"

    def call : JsonResponse
      raise error("Invalid JSON", 400, json_req.error_messages) unless json_req.valid?
      JsonResponse.new json_req
    end
  end
end

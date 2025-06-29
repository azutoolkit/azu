module ExampleApp
  struct JsonEndpoint
    include Azu::Endpoint(JsonReq, JsonResponse)
    post "/json/:id"

    def call : JsonResponse
      status 200
      content_type "application/json"

      raise error("Invalid JSON", 400, json_req.error_messages) unless json_req.valid?

      JsonResponse.new json_req
    end
  end
end

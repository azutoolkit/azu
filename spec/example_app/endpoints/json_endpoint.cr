module ExampleApp
  struct JsonEndpoint
    include Azu::Endpoint(JsonReq, JsonRes)

    def call : JsonRes
      req = JsonReq.from_json(body)
      JsonRes.new req
    end
  end
end

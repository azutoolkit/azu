module ExampleApp
  struct JsonEndpoint
    include Azu::Endpoint(JsonReq, JsonRes)

    def call : JsonRes
      JsonRes.new request
    end
  end
end

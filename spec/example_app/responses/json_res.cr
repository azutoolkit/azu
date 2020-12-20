module ExampleApp
  struct JsonRes
    include Response::Json
    include JSON::Serializable

    def initialize(@request : JsonReq)
    end

    def json
      @request.to_json
    end
  end
end

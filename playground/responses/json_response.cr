module ExampleApp
  struct JsonResponse
    include JSON::Serializable
    include Azu::Response

    def initialize(@request : JsonReq)
    end

    def render
      @request.to_json
    end
  end
end

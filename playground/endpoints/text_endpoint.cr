module ExampleApp
  struct TextEndpoint
    include Endpoint(ExampleReq, TextResponse)

    get "/text/"

    @hello_world = TextResponse.new

    def call : TextResponse
      content_type "text/plain"
      status 201
      @hello_world
    end
  end
end

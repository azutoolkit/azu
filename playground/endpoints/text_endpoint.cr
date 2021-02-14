module ExampleApp
  struct TextEndpoint
    include Endpoint(ExampleReq, TextResponse)

    get "/text/", accept: "text/html", content_type: "text/html"
    @hello_world = TextResponse.new

    def call : TextResponse
      @hello_world
    end
  end
end

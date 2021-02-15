module ExampleApp
  struct TextEndpoint
    include Endpoint(ExampleReq, TextResponse)

    get "/text/"
    
    @hello_world = TextResponse.new

    def call : TextResponse
      @hello_world
    end
  end
end

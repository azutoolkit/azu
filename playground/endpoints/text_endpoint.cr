module ExampleApp
  struct TextEndpoint
    include Azu::Endpoint(ExampleReq, TextResponse)

    get "/text/"

    @hello_world = TextResponse.new

    def call : TextResponse
      content_type "text/plain"
      status 201
      TextResponse.new("Hello World!")
    end
  end
end

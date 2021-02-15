module ExampleApp
  struct HtmlEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    
    get "/html/:name"

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end

module ExampleApp
  struct HtmlEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    
    get "/html/:name"

    def call : HtmlPage
      status 200
      content_type "text/html"
      HtmlPage.new example_req.name
    end
  end
end

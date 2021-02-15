module ExampleApp
  struct LoadEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    get "/load/:name"

    def call : HtmlPage
      status 201
      content_type "text/html"
      HtmlPage.new example_req.name
    end
  end
end

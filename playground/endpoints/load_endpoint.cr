module ExampleApp
  struct LoadEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    get "/load/:name"

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end

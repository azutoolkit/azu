module ExampleApp
  struct LoadEndpoint
    include Endpoint(ExampleReq, HtmlPage)
    get "/load/:name", accept: "text/html", content_type: "text/html"

    def call : HtmlPage
      HtmlPage.new example_req.name
    end
  end
end
